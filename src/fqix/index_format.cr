require "./binary_io"
require "./error"
require "./window_store"

module Fqix
  module IndexFormat
    extend self

    MAGIC                = "FQIX\u{1}\0\0\0"
    VERSION              =  3_u32
    V3_HEADER_SIZE       = 72_u64
    CHECKPOINT_META_SIZE = 21_u64

    def write(index : Index, path : String) : Nil
      File.open(path, "wb") do |io|
        source_path_bytes = index.source_path.to_slice
        if source_path_bytes.size > UInt32::MAX
          raise Error.new("source path too long for index: #{index.source_path}")
        end

        windows_offset = V3_HEADER_SIZE +
                         source_path_bytes.size.to_u64 +
                         index.checkpoint_metas.size.to_u64 * CHECKPOINT_META_SIZE +
                         name_table_size(index.names)

        io.write(MAGIC.to_slice)
        BinaryIO.write_u32(io, VERSION)
        BinaryIO.write_u16(io, 0_u16) # flags, reserved
        BinaryIO.write_u16(io, 0_u16) # header padding
        BinaryIO.write_u64(io, index.source_size)
        BinaryIO.write_i64(io, index.source_mtime)
        BinaryIO.write_u64(io, index.checkpoint_span)
        BinaryIO.write_u32(io, index.name_interval)
        BinaryIO.write_u32(io, source_path_bytes.size.to_u32)
        BinaryIO.write_u64(io, index.checkpoint_metas.size.to_u64)
        BinaryIO.write_u64(io, index.names.size.to_u64)
        BinaryIO.write_u64(io, windows_offset)
        io.write(source_path_bytes)

        index.checkpoint_metas.each do |checkpoint|
          write_checkpoint_meta(io, checkpoint)
        end

        index.names.each do |entry|
          write_name_entry(io, entry)
        end

        unless io.pos.to_u64 == windows_offset
          raise Error.new("internal index layout error: window offset mismatch")
        end

        index.checkpoint_metas.each_index do |checkpoint_id|
          io.write(index.checkpoint_window(checkpoint_id))
        end
      end
    end

    def read(path : String) : Index
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

        Index.new(
          source_path,
          source_size,
          source_mtime,
          checkpoint_span,
          name_interval,
          checkpoint_metas,
          names,
          FileWindowStore.new(path, windows_offset),
          version
        )
      end
    end

    private def name_table_size(names : Array(NameEntry)) : UInt64
      names.sum(0_u64) do |entry|
        name_size = entry.name.bytesize
        if name_size > UInt16::MAX
          raise Error.new("read name too long for index: #{entry.name}")
        end
        2_u64 + name_size.to_u64 + 8_u64 + 8_u64 + 8_u64
      end
    end

    private def write_checkpoint_meta(io : IO, checkpoint : CheckpointMeta) : Nil
      BinaryIO.write_u64(io, checkpoint.out_offset)
      BinaryIO.write_u64(io, checkpoint.in_offset)
      BinaryIO.write_u8(io, checkpoint.bits)
      BinaryIO.write_u32(io, checkpoint.have)
    end

    private def read_checkpoint_meta(io : IO) : CheckpointMeta
      out_offset = BinaryIO.read_u64(io)
      in_offset = BinaryIO.read_u64(io)
      bits = BinaryIO.read_u8(io)
      have = BinaryIO.read_u32(io)
      CheckpointMeta.new(out_offset, in_offset, bits, have)
    end

    private def write_name_entry(io : IO, entry : NameEntry) : Nil
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

    private def read_name_entry(io : IO) : NameEntry
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
