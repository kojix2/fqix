require "./error"
require "./fastq"
require "./index_format"
require "./order"
require "./window_store"
require "./zran"

module Fqix
  struct NameEntry
    getter name : String
    getter uncompressed_offset : UInt64
    getter checkpoint_id : UInt64
    getter delta : UInt64

    def initialize(@name : String, @uncompressed_offset : UInt64, @checkpoint_id : UInt64, @delta : UInt64)
    end
  end

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

  # Builds the sparse read-name anchor list while the gzip stream is inflated
  # once for the zran checkpoint pass. Decompressed bytes arrive in arbitrary
  # chunks (split across deflate blocks and gzip members), so this records
  # header bytes and record offsets without materializing sequence/quality lines.
  class NameTableBuilder
    record Anchor, name : String, offset : UInt64

    getter anchors : Array(Anchor)

    def initialize(@name_interval : UInt32)
      @anchors = [] of Anchor
      @record_index = 0_u64
      @last_name = nil.as(String?)
      @header = IO::Memory.new # bytes of the current header line (line 0 only)
      @framer = Fastq::StreamParser.new(
        ->(segment : Bytes, line_in_record : Int32, _line_start : UInt64) {
          @header.write(segment) if line_in_record == 0
        },
        ->(record_start : UInt64) {
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

    private def complete_record(name : String, record_start : UInt64) : Nil
      if last = @last_name
        if Order.compare(name, last) < 0
          raise Error.new("FASTQ is not sorted by read name near #{name.inspect} < #{last.inspect}")
        end
      end
      @last_name = name

      if @record_index == 0 || @record_index % @name_interval == 0
        @anchors << Anchor.new(name, record_start)
      end
      @record_index += 1
    end
  end

  class Index
    MAGIC                   = IndexFormat::MAGIC
    VERSION                 = IndexFormat::VERSION
    DEFAULT_CHECKPOINT_SPAN = 4_u64 * 1024_u64 * 1024_u64
    DEFAULT_NAME_INTERVAL   = 1024_u32

    getter format_version : UInt32
    property source_path : String
    property source_size : UInt64
    property source_mtime : Int64
    property checkpoint_span : UInt64
    property name_interval : UInt32
    getter checkpoint_metas : Array(CheckpointMeta)
    getter names : Array(NameEntry)

    def initialize(@source_path : String,
                   @source_size : UInt64,
                   @source_mtime : Int64,
                   @checkpoint_span : UInt64,
                   @name_interval : UInt32,
                   @checkpoint_metas : Array(CheckpointMeta),
                   @names : Array(NameEntry),
                   @window_store : WindowStore,
                   @format_version : UInt32 = VERSION)
    end

    def self.default_path(gz_path : String) : String
      "#{gz_path}.fqix"
    end

    def self.build(gz_path : String,
                   checkpoint_span : UInt64 = DEFAULT_CHECKPOINT_SPAN,
                   name_interval : UInt32 = DEFAULT_NAME_INTERVAL) : Index
      raise Error.new("name interval must be greater than zero") if name_interval == 0
      raise Error.new("checkpoint span must be greater than zero") if checkpoint_span == 0

      info = File.info(gz_path)

      builder = NameTableBuilder.new(name_interval)
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
      names = build_name_table(checkpoint_metas, builder.anchors)
      new(
        gz_path,
        info.size.to_u64,
        info.modification_time.to_unix,
        checkpoint_span,
        name_interval,
        checkpoint_metas,
        names,
        MemoryWindowStore.new(windows)
      )
    end

    def self.build_name_table(checkpoints : Array(CheckpointMeta),
                              anchors : Array(NameTableBuilder::Anchor)) : Array(NameEntry)
      anchors.map do |anchor|
        cp_id = checkpoint_for(checkpoints, anchor.offset)
        cp = checkpoints[cp_id]
        NameEntry.new(anchor.name, anchor.offset, cp_id.to_u64, anchor.offset - cp.out_offset)
      end
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

    # Returns the anchor to start scanning from for `query`: the last anchor
    # ordering strictly before `query`. Using strict `<` (rather than `<=`) and
    # clamping to the first record means the scan begins at or before the start
    # of `query`'s equal-ordered run, so it works for weak orders and when
    # `query` equals the very first record. The first FASTQ record is always an
    # anchor, so index 0 is a safe lower bound.
    def find_floor_name(query : String) : NameEntry?
      return if names.empty?
      lo = 0
      hi = names.size
      while lo < hi
        mid = (lo + hi) // 2
        if Order.compare(names[mid].name, query) < 0
          lo = mid + 1
        else
          hi = mid
        end
      end
      idx = lo - 1
      names[idx < 0 ? 0 : idx]
    end
  end
end
