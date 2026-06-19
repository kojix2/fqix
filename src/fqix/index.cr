require "./error"
require "./fastq"
require "./index_format"
require "./mphf"
require "./order"
require "./window_store"
require "./zran"

module Fqix
  enum IndexMode : UInt8
    Sparse = 1
    Exact  = 2
  end

  # On-disk format version, split into two orthogonal axes so each index kind
  # can evolve on its own. `major` is the index kind (1 = sparse, 2 = exact),
  # `minor` is a revision within that kind. Stored as two little-endian u16
  # fields, which is byte-compatible with the older single u32 version: the
  # released exact value `2` decodes as `2.0`, sparse `1` as `1.0`.
  struct FormatVersion
    getter major : UInt16
    getter minor : UInt16

    def initialize(@major : UInt16, @minor : UInt16)
    end

    def to_s(io : IO) : Nil
      io << major << '.' << minor
    end
  end

  enum HashAlgorithm : UInt8
    Fnv1a64  =   1
    TestZero = 255
  end

  enum NameMode : UInt8
    FirstToken = 1
  end

  # Sparse v1 anchor entry. A sparse index stores only every Nth read name,
  # then scans forward from the nearest lower anchor. It is compact but requires
  # the input FASTQ to be sorted by the same order used by Fqix::Order.
  struct NameEntry
    getter name : String
    getter uncompressed_offset : UInt64
    getter checkpoint_id : UInt64
    getter delta : UInt64

    def initialize(@name : String, @uncompressed_offset : UInt64, @checkpoint_id : UInt64, @delta : UInt64)
    end
  end

  # Exact v2.1 entry. An exact index stores one compact candidate entry for
  # every FASTQ record, sorted by read-name fingerprint, and verifies the
  # extracted FASTQ header before returning a match.
  struct Entry
    getter fingerprint : UInt64
    getter record_offset : UInt64
    getter record_size : UInt32

    def initialize(@fingerprint : UInt64,
                   @record_offset : UInt64,
                   @record_size : UInt32)
    end
  end

  # Exact v2.2 inline slot. A slot either stores one record directly, or an
  # overflow table reference for duplicate/colliding 64-bit keys.
  struct ExactSlot
    FLAG_OVERFLOW = 1_u8

    getter value : UInt64
    getter count_or_size : UInt32
    getter guard : UInt8
    getter flags : UInt8

    def initialize(@value : UInt64,
                   @count_or_size : UInt32,
                   @guard : UInt8,
                   @flags : UInt8)
    end

    def overflow? : Bool
      (flags & FLAG_OVERFLOW) != 0
    end

    def record_offset : UInt64
      value
    end

    def record_size : UInt32
      count_or_size
    end

    def overflow_offset : UInt64
      value
    end

    def overflow_count : UInt32
      count_or_size
    end
  end

  struct ExactOverflowEntry
    getter record_offset : UInt64
    getter record_size : UInt32
    getter guard : UInt8

    def initialize(@record_offset : UInt64,
                   @record_size : UInt32,
                   @guard : UInt8)
    end
  end

  struct ExactCandidate
    getter record_offset : UInt64
    getter record_size : UInt32

    def initialize(@record_offset : UInt64,
                   @record_size : UInt32)
    end
  end

  record RawEntry, name : String, record_offset : UInt64, record_size : UInt64

  struct CheckpointMeta
    getter out_offset : UInt64
    getter in_offset : UInt64
    getter bits : UInt8
    getter have : UInt32

    def initialize(@out_offset : UInt64, @in_offset : UInt64, @bits : UInt8, @have : UInt32)
    end

    def self.from_checkpoint(checkpoint : Zran::Checkpoint) : CheckpointMeta
      new(checkpoint.out_offset, checkpoint.in_offset, checkpoint.bits, checkpoint.have)
    end
  end

  module NameHash
    extend self

    FNV_OFFSET = 14_695_981_039_346_656_037_u64
    FNV_PRIME  =          1_099_511_628_211_u64

    def hash(name : String, algorithm : HashAlgorithm, seed : UInt64) : UInt64
      case algorithm
      in .fnv1a64?
        fnv1a64(name, seed)
      in .test_zero?
        0_u64
      end
    end

    private def fnv1a64(name : String, seed : UInt64) : UInt64
      value = FNV_OFFSET ^ seed
      name.to_slice.each do |byte|
        value = (value ^ byte.to_u64) & UInt64::MAX
        value = (value &* FNV_PRIME) & UInt64::MAX
      end
      value
    end
  end

  # Builds the sparse v1 read-name anchor list while gzip is inflated once for
  # the zran checkpoint pass.
  class SparseNameTableBuilder
    record Anchor, name : String, offset : UInt64

    # Candidate read-name orders tried during build, in auto-detection
    # precedence (the first monotonic one wins when the order is `auto`).
    ORDER_CANDIDATES = [OrderMode::Lexicographic, OrderMode::Natural]

    getter anchors : Array(Anchor)
    getter record_count = 0_u64

    def initialize(@name_interval : UInt32)
      @anchors = [] of Anchor
      @record_index = 0_u64
      @last_name = nil.as(String?)
      @monotonic = Hash(OrderMode, Bool).new
      @first_violation = Hash(OrderMode, Tuple(String, String)).new
      ORDER_CANDIDATES.each { |mode| @monotonic[mode] = true }
      @header = IO::Memory.new
      @framer = Fastq::StreamParser.new(
        ->(segment : Bytes, line_in_record : Int32, _line_start : UInt64) {
          @header.write(segment) if line_in_record == 0
        },
        ->(record_start : UInt64, _record_size : UInt64) {
          complete_record(Fastq.name_from_header(@header.to_s), record_start)
          @header.clear
          true
        }
      )
    end

    def feed(chunk : Bytes) : Nil
      @framer.feed(chunk)
    end

    def finish : Nil
      @framer.finish
    end

    # Whether the read names seen so far are monotonic under `mode`.
    def monotonic?(mode : OrderMode) : Bool
      @monotonic.fetch(mode, false)
    end

    # The first {previous, current} inversion observed under `mode`, if any.
    def first_violation(mode : OrderMode) : Tuple(String, String)?
      @first_violation[mode]?
    end

    private def complete_record(name : String, record_start : UInt64) : Nil
      if last = @last_name
        ORDER_CANDIDATES.each do |mode|
          next unless @monotonic[mode]
          if Order.compare(name, last, mode) < 0
            @monotonic[mode] = false
            @first_violation[mode] = {last, name}
          end
        end
      end
      @last_name = name

      if @record_index == 0 || @record_index % @name_interval == 0
        @anchors << Anchor.new(name, record_start)
      end
      @record_index += 1
      @record_count = @record_index
    end
  end

  # Records every FASTQ record for exact v2 mode. Decompressed bytes can be split
  # anywhere, so only header bytes and record offsets/sizes are retained.
  class ExactEntryBuilder
    getter records : Array(RawEntry)
    getter? input_names_sorted = true

    def initialize
      @records = [] of RawEntry
      @record_index = 0_u64
      @last_name = nil.as(String?)
      @header = IO::Memory.new
      @framer = Fastq::StreamParser.new(
        ->(segment : Bytes, line_in_record : Int32, _line_start : UInt64) {
          @header.write(segment) if line_in_record == 0
        },
        ->(record_start : UInt64, record_size : UInt64) {
          complete_record(Fastq.name_from_header(@header.to_s), record_start, record_size)
          @header.clear
          true
        }
      )
    end

    def feed(chunk : Bytes) : Nil
      @framer.feed(chunk)
    end

    def finish : Nil
      @framer.finish
    end

    private def complete_record(name : String, record_start : UInt64, record_size : UInt64) : Nil
      if last = @last_name
        @input_names_sorted = false if Order.lexicographic_compare(name, last) < 0
      end
      @last_name = name

      @records << RawEntry.new(name, record_start, record_size)
      @record_index += 1
    end
  end

  class Index
    MAGIC                   = IndexFormat::MAGIC_V2
    VERSION                 = IndexFormat::EXACT_VERSION
    DEFAULT_CHECKPOINT_SPAN = 4_u64 * 1024_u64 * 1024_u64
    DEFAULT_NAME_INTERVAL   = 1024_u32
    DEFAULT_MODE            = IndexMode::Sparse
    DEFAULT_HASH_ALGORITHM  = HashAlgorithm::Fnv1a64
    DEFAULT_HASH_SEED       = 0_u64
    DEFAULT_NAME_MODE       = NameMode::FirstToken
    DEFAULT_ORDER_MODE      = OrderMode::Lexicographic

    getter format_version : FormatVersion
    property source_path : String
    property source_size : UInt64
    property source_mtime : Int64
    property checkpoint_span : UInt64
    property mode : IndexMode
    property name_interval : UInt32
    property order_mode : OrderMode
    property fingerprint_algorithm : HashAlgorithm
    property fingerprint_seed : UInt64
    property name_mode : NameMode
    property record_count : UInt64
    property? input_names_sorted : Bool
    getter checkpoint_metas : Array(CheckpointMeta)
    getter names : Array(NameEntry)
    getter entries : Array(Entry)
    getter mphf : Mphf?
    getter slots : Array(ExactSlot)
    getter overflows : Array(ExactOverflowEntry)

    def initialize(@source_path : String,
                   @source_size : UInt64,
                   @source_mtime : Int64,
                   @checkpoint_span : UInt64,
                   @mode : IndexMode,
                   @name_interval : UInt32,
                   @order_mode : OrderMode,
                   @fingerprint_algorithm : HashAlgorithm,
                   @fingerprint_seed : UInt64,
                   @name_mode : NameMode,
                   @record_count : UInt64,
                   @input_names_sorted : Bool,
                   @checkpoint_metas : Array(CheckpointMeta),
                   @names : Array(NameEntry),
                   @entries : Array(Entry),
                   @window_store : WindowStore,
                   @format_version : FormatVersion = VERSION,
                   @mphf : Mphf? = nil,
                   @slots : Array(ExactSlot) = [] of ExactSlot,
                   @overflows : Array(ExactOverflowEntry) = [] of ExactOverflowEntry)
    end

    # Convenience constructor for tests and callers that directly build an exact
    # v2.1 index object.
    def initialize(@source_path : String,
                   @source_size : UInt64,
                   @source_mtime : Int64,
                   @checkpoint_span : UInt64,
                   @fingerprint_algorithm : HashAlgorithm,
                   @fingerprint_seed : UInt64,
                   @name_mode : NameMode,
                   @record_count : UInt64,
                   @input_names_sorted : Bool,
                   @checkpoint_metas : Array(CheckpointMeta),
                   @entries : Array(Entry),
                   @window_store : WindowStore,
                   @format_version : FormatVersion = VERSION,
                   @mphf : Mphf? = nil,
                   @slots : Array(ExactSlot) = [] of ExactSlot,
                   @overflows : Array(ExactOverflowEntry) = [] of ExactOverflowEntry)
      @mode = IndexMode::Exact
      @name_interval = 0_u32
      @order_mode = DEFAULT_ORDER_MODE
      @names = [] of NameEntry
    end

    def self.default_path(gz_path : String) : String
      "#{gz_path}.fqix"
    end

    def self.build(gz_path : String,
                   checkpoint_span : UInt64 = DEFAULT_CHECKPOINT_SPAN,
                   mode : IndexMode = DEFAULT_MODE,
                   name_interval : UInt32 = DEFAULT_NAME_INTERVAL,
                   order_mode : OrderMode? = nil) : Index
      raise Error.new("checkpoint span must be greater than zero") if checkpoint_span == 0

      case mode
      in .sparse?
        build_sparse(gz_path, checkpoint_span, name_interval, order_mode)
      in .exact?
        build_exact(gz_path, checkpoint_span)
      end
    end

    # `order_mode` is the requested sparse read-name order; `nil` means auto —
    # try each `SparseNameTableBuilder::ORDER_CANDIDATES` in precedence and
    # persist the first one the FASTQ is monotonic under.
    def self.build_sparse(gz_path : String,
                          checkpoint_span : UInt64 = DEFAULT_CHECKPOINT_SPAN,
                          name_interval : UInt32 = DEFAULT_NAME_INTERVAL,
                          order_mode : OrderMode? = nil) : Index
      raise Error.new("name interval must be greater than zero") if name_interval == 0
      raise Error.new("checkpoint span must be greater than zero") if checkpoint_span == 0

      info = File.info(gz_path)
      builder = SparseNameTableBuilder.new(name_interval)
      tmp = build_zran_temp(gz_path, checkpoint_span, builder)
      begin
        checkpoints = Zran.read_temp(tmp)
      ensure
        File.delete(tmp) if File.exists?(tmp)
      end
      builder.finish

      resolved_order = resolve_sparse_order(builder, order_mode)
      checkpoint_metas = checkpoints.map { |checkpoint| CheckpointMeta.from_checkpoint(checkpoint) }
      windows = checkpoints.map(&.window)
      names = build_name_table(checkpoint_metas, builder.anchors)
      new(
        gz_path,
        info.size.to_u64,
        info.modification_time.to_unix,
        checkpoint_span,
        IndexMode::Sparse,
        name_interval,
        resolved_order,
        DEFAULT_HASH_ALGORITHM,
        DEFAULT_HASH_SEED,
        DEFAULT_NAME_MODE,
        builder.record_count,
        true,
        checkpoint_metas,
        names,
        [] of Entry,
        MemoryWindowStore.new(windows),
        IndexFormat::SPARSE_VERSION,
        nil,
        [] of ExactSlot,
        [] of ExactOverflowEntry
      )
    end

    # Resolve the concrete sparse order to persist. A specific request must be
    # monotonic or it fails; `nil` (auto) picks the first monotonic candidate.
    private def self.resolve_sparse_order(builder : SparseNameTableBuilder, requested : OrderMode?) : OrderMode
      if requested
        return requested if builder.monotonic?(requested)
        raise Error.new(sparse_order_failure_message(builder, requested))
      end

      chosen = SparseNameTableBuilder::ORDER_CANDIDATES.find { |mode| builder.monotonic?(mode) }
      return chosen if chosen

      tried = SparseNameTableBuilder::ORDER_CANDIDATES.map { |mode| order_mode_label(mode) }.join(", ")
      raise Error.new("FASTQ is not sorted under any built-in --name-order (tried #{tried}); sort the file or use --mode exact")
    end

    private def self.sparse_order_failure_message(builder : SparseNameTableBuilder, requested : OrderMode) : String
      alternatives = SparseNameTableBuilder::ORDER_CANDIDATES.select do |mode|
        mode != requested && builder.monotonic?(mode)
      end
      suffix =
        if alternatives.empty?
          "sort the file, or use --mode exact"
        else
          labels = alternatives.map { |mode| order_mode_label(mode) }.join(" or ")
          "try --name-order #{labels}, sort the file, or use --mode exact"
        end

      if violation = builder.first_violation(requested)
        prev, cur = violation
        "FASTQ is not sorted under --name-order #{order_mode_label(requested)} near #{cur.inspect} < #{prev.inspect}; #{suffix}"
      else
        "FASTQ is not sorted under --name-order #{order_mode_label(requested)}; #{suffix}"
      end
    end

    def self.build_exact(gz_path : String,
                         checkpoint_span : UInt64 = DEFAULT_CHECKPOINT_SPAN) : Index
      raise Error.new("checkpoint span must be greater than zero") if checkpoint_span == 0

      info = File.info(gz_path)
      builder = ExactEntryBuilder.new
      tmp = build_zran_temp(gz_path, checkpoint_span, builder)
      begin
        checkpoints = Zran.read_temp(tmp)
      ensure
        File.delete(tmp) if File.exists?(tmp)
      end
      builder.finish

      checkpoint_metas = checkpoints.map { |checkpoint| CheckpointMeta.from_checkpoint(checkpoint) }
      windows = checkpoints.map(&.window)
      mphf, slots, overflows = build_mphf_tables(builder.records, DEFAULT_HASH_ALGORITHM, DEFAULT_HASH_SEED)
      new(
        gz_path,
        info.size.to_u64,
        info.modification_time.to_unix,
        checkpoint_span,
        IndexMode::Exact,
        0_u32,
        DEFAULT_ORDER_MODE,
        DEFAULT_HASH_ALGORITHM,
        DEFAULT_HASH_SEED,
        DEFAULT_NAME_MODE,
        builder.records.size.to_u64,
        builder.input_names_sorted?,
        checkpoint_metas,
        [] of NameEntry,
        [] of Entry,
        MemoryWindowStore.new(windows),
        IndexFormat::EXACT_VERSION,
        mphf,
        slots,
        overflows
      )
    end

    private def self.build_zran_temp(gz_path : String, checkpoint_span : UInt64, builder) : String
      consumer = ->(chunk : Bytes) { builder.feed(chunk) }
      Zran.build_to_temp(gz_path, checkpoint_span, consumer)
    end

    def self.build_name_table(checkpoints : Array(CheckpointMeta),
                              anchors : Array(SparseNameTableBuilder::Anchor)) : Array(NameEntry)
      anchors.map do |anchor|
        cp_id = checkpoint_for(checkpoints, anchor.offset)
        cp = checkpoints[cp_id]
        NameEntry.new(anchor.name, anchor.offset, cp_id.to_u64, anchor.offset - cp.out_offset)
      end
    end

    def self.build_entries(records : Array(RawEntry),
                           fingerprint_algorithm : HashAlgorithm,
                           fingerprint_seed : UInt64) : Array(Entry)
      sorted = records
        .map { |record| {NameHash.hash(record.name, fingerprint_algorithm, fingerprint_seed), record} }
        .sort_by! { |fingerprint, record| {fingerprint, record.record_offset} }
      entries = Array(Entry).new(sorted.size)
      sorted.each do |fingerprint, record|
        if record.record_size > UInt32::MAX
          raise Error.new("FASTQ record too large for exact index at #{record.record_offset}")
        end
        entries << Entry.new(fingerprint, record.record_offset, record.record_size.to_u32)
      end
      entries
    end

    def self.build_mphf_tables(records : Array(RawEntry),
                               fingerprint_algorithm : HashAlgorithm,
                               fingerprint_seed : UInt64) : Tuple(Mphf, Array(ExactSlot), Array(ExactOverflowEntry))
      grouped = Hash(UInt64, Array(RawEntry)).new { |hash, key| hash[key] = [] of RawEntry }
      records.each do |record|
        grouped[NameHash.hash(record.name, fingerprint_algorithm, fingerprint_seed)] << record
      end

      keys = grouped.keys.sort!
      mphf = Mphf.new(keys, fingerprint_seed)
      slots = Array(ExactSlot).new(keys.size, ExactSlot.new(0_u64, 0_u32, 0_u8, 0_u8))
      overflows = [] of ExactOverflowEntry

      keys.each do |key|
        slot_id = mphf.lookup(key) || raise Error.new("internal mphf build error")
        records_for_key = grouped[key].sort_by!(&.record_offset)
        if records_for_key.size == 1
          record = records_for_key[0]
          slots[slot_id.to_i] = ExactSlot.new(
            record.record_offset,
            checked_record_size(record),
            guard(record.name, fingerprint_seed),
            0_u8
          )
        else
          if records_for_key.size > UInt32::MAX
            raise Error.new("too many FASTQ records for one exact index key")
          end
          overflow_offset = overflows.size.to_u64
          records_for_key.each do |overflow_record|
            overflows << ExactOverflowEntry.new(
              overflow_record.record_offset,
              checked_record_size(overflow_record),
              guard(overflow_record.name, fingerprint_seed)
            )
          end
          slots[slot_id.to_i] = ExactSlot.new(
            overflow_offset,
            records_for_key.size.to_u32,
            0_u8,
            ExactSlot::FLAG_OVERFLOW
          )
        end
      end

      {mphf, slots, overflows}
    end

    private def self.checked_record_size(record : RawEntry) : UInt32
      if record.record_size > UInt32::MAX
        raise Error.new("FASTQ record too large for exact index at #{record.record_offset}")
      end
      record.record_size.to_u32
    end

    def self.guard(name : String, seed : UInt64) : UInt8
      (Mphf.mix(NameHash.hash(name, HashAlgorithm::Fnv1a64, seed ^ 0xD1B54A32D192ED03_u64)) & 0xff_u64).to_u8
    end

    def self.checkpoint_for(checkpoints : Array(CheckpointMeta), out_offset : UInt64) : Int32
      lo = lower_bound(checkpoints.size) { |index| checkpoints[index].out_offset <= out_offset }
      idx = lo - 1
      idx < 0 ? 0 : idx
    end

    def checkpoint(id : Int) : Zran::Checkpoint
      meta = checkpoint_metas[id]
      Zran::Checkpoint.new(meta.out_offset, meta.in_offset, meta.bits, meta.have, checkpoint_window(id))
    end

    def checkpoint_window(id : Int) : Bytes
      @window_store.get(id)
    end

    def write(path : String) : Nil
      IndexFormat.write(self, path)
    end

    def self.read(path : String) : Index
      IndexFormat.read(path)
    end

    def stale_for?(gz_path : String) : Bool
      info = File.info(gz_path)
      info.size.to_u64 != source_size || info.modification_time.to_unix != source_mtime
    end

    def sparse? : Bool
      mode.sparse?
    end

    def exact? : Bool
      mode.exact?
    end

    def self.order_mode_label(mode : OrderMode) : String
      case mode
      in .lexicographic?
        "lex"
      in .natural?
        "natural"
      end
    end

    def order_mode_label : String
      Index.order_mode_label(order_mode)
    end

    def normalize_query(query : String) : String
      case name_mode
      in .first_token?
        index = Fastq.first_whitespace_index(query)
        index ? query[0, index] : query
      end
    end

    def find_entries(query : String) : Array(Entry)
      raise Error.new("index mode is not exact") unless exact?
      return [] of Entry if entries.empty?
      normalized = normalize_query(query)
      fingerprint = NameHash.hash(normalized, fingerprint_algorithm, fingerprint_seed)
      first = lower_bound_fingerprint(fingerprint)
      matches = [] of Entry
      index = first
      while index < entries.size && entries[index].fingerprint == fingerprint
        matches << entries[index]
        index += 1
      end
      matches
    end

    def find_exact_candidates(query : String) : Array(ExactCandidate)
      raise Error.new("index mode is not exact") unless exact?
      if format_version.minor <= 1 || !entries.empty?
        return find_entries(query).map { |entry| ExactCandidate.new(entry.record_offset, entry.record_size) }
      end

      mphf = @mphf
      return [] of ExactCandidate unless mphf
      normalized = normalize_query(query)
      key = NameHash.hash(normalized, fingerprint_algorithm, fingerprint_seed)
      slot_id = mphf.lookup(key)
      return [] of ExactCandidate unless slot_id && slot_id < slots.size.to_u64

      query_guard = Index.guard(normalized, fingerprint_seed)
      slot = slots[slot_id.to_i]
      candidates = [] of ExactCandidate
      if slot.overflow?
        if slot.overflow_offset + slot.overflow_count.to_u64 > overflows.size.to_u64
          raise Error.new("invalid fqix exact overflow reference")
        end
        offset = slot.overflow_offset.to_i
        slot.overflow_count.times do |index|
          entry = overflows[offset + index]
          candidates << ExactCandidate.new(entry.record_offset, entry.record_size) if entry.guard == query_guard
        end
      elsif slot.guard == query_guard
        candidates << ExactCandidate.new(slot.record_offset, slot.record_size)
      end
      candidates
    end

    # Returns the anchor to start scanning from for `query`: the last anchor
    # ordering strictly before `query`. The first FASTQ record is always an
    # anchor, so index 0 is a safe lower bound.
    def find_floor_name(query : String, normalized : Bool = false) : NameEntry?
      raise Error.new("index mode is not sparse") unless sparse?
      return if names.empty?
      normalized_query = normalized ? query : normalize_query(query)
      lo = Index.lower_bound(names.size) { |index| Order.compare(names[index].name, normalized_query, order_mode) < 0 }
      idx = lo - 1
      names[idx < 0 ? 0 : idx]
    end

    private def lower_bound_fingerprint(fingerprint : UInt64) : Int32
      Index.lower_bound(entries.size) { |index| entries[index].fingerprint < fingerprint }
    end

    def self.lower_bound(size : Int32, &before_target : Int32 -> Bool) : Int32
      lo = 0
      hi = size
      while lo < hi
        mid = (lo + hi) // 2
        if before_target.call(mid)
          lo = mid + 1
        else
          hi = mid
        end
      end
      lo
    end
  end
end
