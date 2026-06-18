require "./error"
require "./fastq"
require "./index_format"
require "./window_store"
require "./zran"

module Fqix
  enum HashAlgorithm : UInt8
    Fnv1a64  =   1
    TestZero = 255
  end

  enum NameMode : UInt8
    FirstToken = 1
  end

  struct Entry
    getter name_hash : UInt64
    getter name_offset : UInt64
    getter name_length : UInt32
    getter record_number : UInt64
    getter record_offset : UInt64
    getter record_size : UInt64
    getter flags : UInt32

    def initialize(@name_hash : UInt64,
                   @name_offset : UInt64,
                   @name_length : UInt32,
                   @record_number : UInt64,
                   @record_offset : UInt64,
                   @record_size : UInt64,
                   @flags : UInt32 = 0_u32)
    end
  end

  record RawEntry, name : String, record_number : UInt64, record_offset : UInt64, record_size : UInt64

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

  # Records every FASTQ record while gzip is inflated once for the zran
  # checkpoint pass. Decompressed bytes can be split anywhere, so only header
  # bytes and record offsets/sizes are retained.
  class EntryBuilder
    getter records : Array(RawEntry)
    getter? input_names_sorted = true

    def initialize
      @records = [] of RawEntry
      @record_index = 0_u64
      @last_name = nil.as(String?)
      @header = IO::Memory.new # bytes of the current header line (line 0 only)
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
        @input_names_sorted = false if name < last
      end
      @last_name = name

      @records << RawEntry.new(name, @record_index, record_start, record_size)
      @record_index += 1
    end
  end

  class Index
    MAGIC                   = IndexFormat::MAGIC
    VERSION                 = IndexFormat::VERSION
    DEFAULT_CHECKPOINT_SPAN = 4_u64 * 1024_u64 * 1024_u64
    DEFAULT_HASH_ALGORITHM  = HashAlgorithm::Fnv1a64
    DEFAULT_HASH_SEED       = 0_u64
    DEFAULT_NAME_MODE       = NameMode::FirstToken

    getter format_version : UInt32
    property source_path : String
    property source_size : UInt64
    property source_mtime : Int64
    property checkpoint_span : UInt64
    property hash_algorithm : HashAlgorithm
    property hash_seed : UInt64
    property name_mode : NameMode
    property record_count : UInt64
    property? input_names_sorted : Bool
    getter checkpoint_metas : Array(CheckpointMeta)
    getter entries : Array(Entry)
    getter name_table : Bytes

    def initialize(@source_path : String,
                   @source_size : UInt64,
                   @source_mtime : Int64,
                   @checkpoint_span : UInt64,
                   @hash_algorithm : HashAlgorithm,
                   @hash_seed : UInt64,
                   @name_mode : NameMode,
                   @record_count : UInt64,
                   @input_names_sorted : Bool,
                   @checkpoint_metas : Array(CheckpointMeta),
                   @entries : Array(Entry),
                   @name_table : Bytes,
                   @window_store : WindowStore,
                   @format_version : UInt32 = VERSION)
    end

    def self.default_path(gz_path : String) : String
      "#{gz_path}.fqix"
    end

    def self.build(gz_path : String,
                   checkpoint_span : UInt64 = DEFAULT_CHECKPOINT_SPAN) : Index
      raise Error.new("checkpoint span must be greater than zero") if checkpoint_span == 0

      info = File.info(gz_path)

      builder = EntryBuilder.new
      consumer = ->(chunk : Bytes) { builder.feed(chunk) }
      tmp = Zran.build_to_temp(gz_path, checkpoint_span, consumer)
      begin
        checkpoints = Zran.read_temp(tmp)
      ensure
        File.delete(tmp) if File.exists?(tmp)
      end
      builder.finish

      checkpoint_metas = checkpoints.map { |checkpoint| CheckpointMeta.from_checkpoint(checkpoint) }
      windows = checkpoints.map(&.window)
      entries, name_table = build_entries(builder.records, DEFAULT_HASH_ALGORITHM, DEFAULT_HASH_SEED)
      new(
        gz_path,
        info.size.to_u64,
        info.modification_time.to_unix,
        checkpoint_span,
        DEFAULT_HASH_ALGORITHM,
        DEFAULT_HASH_SEED,
        DEFAULT_NAME_MODE,
        builder.records.size.to_u64,
        builder.input_names_sorted?,
        checkpoint_metas,
        entries,
        name_table,
        MemoryWindowStore.new(windows)
      )
    end

    def self.build_entries(records : Array(RawEntry),
                           hash_algorithm : HashAlgorithm,
                           hash_seed : UInt64) : Tuple(Array(Entry), Bytes)
      sorted = records
        .map { |record| {NameHash.hash(record.name, hash_algorithm, hash_seed), record} }
        .sort_by! { |name_hash, record| {name_hash, record.record_number} }
      table = IO::Memory.new
      entries = Array(Entry).new(sorted.size)
      sorted.each do |name_hash, record|
        name_bytes = record.name.to_slice
        raise Error.new("read name too long for index: #{record.name}") if name_bytes.size > UInt32::MAX
        name_offset = table.pos.to_u64
        table.write(name_bytes)
        entries << Entry.new(
          name_hash,
          name_offset,
          name_bytes.size.to_u32,
          record.record_number,
          record.record_offset,
          record.record_size
        )
      end
      {entries, table.to_slice}
    end

    def self.checkpoint_for(checkpoints : Array(CheckpointMeta), out_offset : UInt64) : Int32
      lo = 0
      hi = checkpoints.size
      while lo < hi
        mid = (lo + hi) // 2
        if checkpoints[mid].out_offset <= out_offset
          lo = mid + 1
        else
          hi = mid
        end
      end
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

    def normalize_query(query : String) : String
      case name_mode
      in .first_token?
        index = Fastq.first_whitespace_index(query)
        index ? query[0, index] : query
      end
    end

    def find_entries(query : String) : Array(Entry)
      return [] of Entry if entries.empty?
      normalized = normalize_query(query)
      hash = NameHash.hash(normalized, hash_algorithm, hash_seed)
      first = lower_bound_hash(hash)
      matches = [] of Entry
      index = first
      while index < entries.size && entries[index].name_hash == hash
        entry = entries[index]
        matches << entry if entry_name(entry) == normalized
        index += 1
      end
      matches.sort_by(&.record_number)
    end

    def entry_name(entry : Entry) : String
      offset = entry.name_offset
      length = entry.name_length
      if offset > name_table.size.to_u64 || length.to_u64 > name_table.size.to_u64 - offset
        raise Error.new("invalid fqix index name table reference")
      end
      String.new(name_table[offset.to_i, length.to_i])
    end

    private def lower_bound_hash(hash : UInt64) : Int32
      lo = 0
      hi = entries.size
      while lo < hi
        mid = (lo + hi) // 2
        if entries[mid].name_hash < hash
          lo = mid + 1
        else
          hi = mid
        end
      end
      lo
    end
  end
end
