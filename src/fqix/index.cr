require "./binary_io"
require "./error"
require "./fastq"
require "./order"
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
  # chunks (split across deflate blocks and gzip members), so this scans for
  # line boundaries incrementally and tracks the uncompressed offset of each
  # record without ever materializing the sequence/quality lines.
  class NameTableBuilder
    NEWLINE = '\n'.ord.to_u8

    record Anchor, name : String, offset : UInt64

    getter anchors : Array(Anchor)

    def initialize(@name_interval : UInt32)
      @anchors = [] of Anchor
      @offset = 0_u64       # total uncompressed bytes seen so far
      @line_start = 0_u64   # offset where the current line began
      @record_start = 0_u64 # offset where the current record began
      @line_in_record = 0   # 0=header, 1=seq, 2=plus, 3=qual
      @record_index = 0_u64
      @last_name = nil.as(String?)
      @current_name = ""       # name of the record currently being assembled
      @header = IO::Memory.new # bytes of the current header line (line 0 only)
      @pending = false         # bytes buffered for the current unterminated line
    end

    def feed(chunk : Bytes) : Nil
      i = 0
      size = chunk.size
      while i < size
        if nl = chunk.index(NEWLINE, i)
          stop = nl + 1
          @header.write(chunk[i, stop - i]) if @line_in_record == 0
          @offset += stop - i
          finalize_line
          i = stop
        else
          @header.write(chunk[i, size - i]) if @line_in_record == 0
          @offset += size - i
          @pending = true
          i = size
        end
      end
    end

    def finish : Nil
      finalize_line if @pending
      raise Error.new("truncated FASTQ record at end of stream") if @line_in_record != 0
    end

    private def finalize_line : Nil
      if @line_in_record == 0
        @record_start = @line_start
        @current_name = Fastq.parse_read_name(@header.to_s)
        @header.clear
      end

      @line_in_record += 1
      if @line_in_record == 4
        complete_record
        @line_in_record = 0
      end

      @pending = false
      @line_start = @offset
    end

    private def complete_record : Nil
      name = @current_name
      if last = @last_name
        if Order.compare(name, last) < 0
          raise Error.new("FASTQ is not sorted by read name near #{name.inspect} < #{last.inspect}")
        end
      end
      @last_name = name

      if @record_index == 0 || @record_index % @name_interval == 0
        @anchors << Anchor.new(name, @record_start)
      end
      @record_index += 1
    end
  end

  class Index
    MAGIC                   = "FQIX\u{1}\0\0\0"
    VERSION                 =  3_u32
    V3_HEADER_SIZE          = 72_u64
    CHECKPOINT_META_SIZE    = 21_u64
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
                   @windows : Array(Bytes)?,
                   @index_path : String?,
                   @windows_offset : UInt64,
                   @format_version : UInt32 = VERSION)
      @cached_checkpoint_id = nil.as(Int32?)
      @cached_window = nil.as(Bytes?)
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
        windows,
        nil,
        0_u64
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
      Zran::Checkpoint.new(meta.out_offset, meta.in_offset, meta.bits, meta.have, window_for(id))
    end

    def write(path : String)
      File.open(path, "wb") do |io|
        source_path_bytes = source_path.to_slice
        if source_path_bytes.size > UInt32::MAX
          raise Error.new("source path too long for index: #{source_path}")
        end

        windows_offset = V3_HEADER_SIZE +
                         source_path_bytes.size.to_u64 +
                         checkpoint_metas.size.to_u64 * CHECKPOINT_META_SIZE +
                         name_table_size

        io.write(MAGIC.to_slice)
        BinaryIO.write_u32(io, VERSION)
        BinaryIO.write_u16(io, 0_u16) # flags, reserved
        BinaryIO.write_u16(io, 0_u16) # header padding
        BinaryIO.write_u64(io, source_size)
        BinaryIO.write_i64(io, source_mtime)
        BinaryIO.write_u64(io, checkpoint_span)
        BinaryIO.write_u32(io, name_interval)
        BinaryIO.write_u32(io, source_path_bytes.size.to_u32)
        BinaryIO.write_u64(io, checkpoint_metas.size.to_u64)
        BinaryIO.write_u64(io, names.size.to_u64)
        BinaryIO.write_u64(io, windows_offset)
        io.write(source_path_bytes)

        checkpoint_metas.each do |checkpoint|
          write_checkpoint_meta(io, checkpoint)
        end

        names.each do |entry|
          write_name_entry(io, entry)
        end

        unless io.pos.to_u64 == windows_offset
          raise Error.new("internal index layout error: window offset mismatch")
        end

        checkpoint_metas.each_index do |index|
          io.write(window_for(index))
        end
      end
    end

    def self.read(path : String) : Index
      File.open(path, "rb") do |io|
        magic = Bytes.new(8)
        io.read_fully(magic)
        unless String.new(magic) == MAGIC
          raise Error.new("invalid fqix index magic")
        end
        version = BinaryIO.read_u32(io)
        unless version == VERSION
          raise Error.new("unsupported fqix version #{version}; please rebuild the index")
        end
        BinaryIO.read_u16(io) # flags
        BinaryIO.read_u16(io) # padding
        source_size = BinaryIO.read_u64(io)
        source_mtime = BinaryIO.read_i64(io)
        checkpoint_span = BinaryIO.read_u64(io)
        name_interval = BinaryIO.read_u32(io)
        source_path_len = BinaryIO.read_u32(io)
        ncheckpoints = BinaryIO.read_u64(io)
        nnames = BinaryIO.read_u64(io)
        windows_offset = BinaryIO.read_u64(io)
        path_buf = Bytes.new(source_path_len)
        io.read_fully(path_buf)
        source_path = String.new(path_buf)

        checkpoint_metas = Array(CheckpointMeta).new(ncheckpoints.to_i)
        ncheckpoints.times do
          checkpoint_metas << read_checkpoint_meta(io)
        end

        names = Array(NameEntry).new(nnames.to_i)
        nnames.times do
          names << read_name_entry(io)
        end

        if io.pos.to_u64 != windows_offset
          raise Error.new("invalid fqix index window offset")
        end

        new(
          source_path,
          source_size,
          source_mtime,
          checkpoint_span,
          name_interval,
          checkpoint_metas,
          names,
          nil,
          path,
          windows_offset,
          version
        )
      end
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

    private def window_for(id : Int) : Bytes
      if windows = @windows
        return windows[id]
      end

      id = id.to_i
      if @cached_checkpoint_id == id
        if window = @cached_window
          return window
        end
      end

      path = @index_path || raise Error.new("index checkpoint windows are not available")
      window = Bytes.new(Zran::WINDOW_SIZE)
      File.open(path, "rb") do |io|
        offset = @windows_offset + id.to_u64 * Zran::WINDOW_SIZE.to_u64
        io.seek(offset.to_i64, IO::Seek::Set)
        io.read_fully(window)
      end

      @cached_checkpoint_id = id
      @cached_window = window
      window
    end

    private def name_table_size : UInt64
      names.sum(0_u64) do |entry|
        name_size = entry.name.bytesize
        if name_size > UInt16::MAX
          raise Error.new("read name too long for index: #{entry.name}")
        end
        2_u64 + name_size.to_u64 + 8_u64 + 8_u64 + 8_u64
      end
    end

    private def write_checkpoint_meta(io : IO, checkpoint : CheckpointMeta)
      BinaryIO.write_u64(io, checkpoint.out_offset)
      BinaryIO.write_u64(io, checkpoint.in_offset)
      BinaryIO.write_u8(io, checkpoint.bits)
      BinaryIO.write_u32(io, checkpoint.have)
    end

    private def self.read_checkpoint_meta(io : IO) : CheckpointMeta
      out_offset = BinaryIO.read_u64(io)
      in_offset = BinaryIO.read_u64(io)
      bits = BinaryIO.read_u8(io)
      have = BinaryIO.read_u32(io)
      CheckpointMeta.new(out_offset, in_offset, bits, have)
    end

    private def write_name_entry(io : IO, entry : NameEntry)
      name_bytes = entry.name.to_slice
      if name_bytes.size > UInt16::MAX
        raise Error.new("read name too long for index: #{entry.name}")
      end
      BinaryIO.write_u16(io, name_bytes.size.to_u16)
      io.write(name_bytes)
      BinaryIO.write_u64(io, entry.uncompressed_offset)
      BinaryIO.write_u64(io, entry.checkpoint_id)
      BinaryIO.write_u64(io, entry.delta)
    end

    private def self.read_name_entry(io : IO) : NameEntry
      len = BinaryIO.read_u16(io)
      buf = Bytes.new(len)
      io.read_fully(buf)
      name = String.new(buf)
      uncompressed_offset = BinaryIO.read_u64(io)
      checkpoint_id = BinaryIO.read_u64(io)
      delta = BinaryIO.read_u64(io)
      NameEntry.new(name, uncompressed_offset, checkpoint_id, delta)
    end
  end
end
