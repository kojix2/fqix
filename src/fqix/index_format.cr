require "./binary_io"
require "./error"
require "./window_store"

module Fqix
  module IndexFormat
    extend self

    MAGIC                = "FQIX\u{2}\0\0\0"
    VERSION              =   2_u32
    HEADER_SIZE          = 112_u64
    CHECKPOINT_META_SIZE =  21_u64
    ENTRY_SIZE           =  48_u64
    MAX_ARRAY_SIZE       = Int32::MAX.to_u64

    def write(index : Index, path : String) : Nil
      File.open(path, "wb") do |io|
        source_path_bytes = index.source_path.to_slice
        if source_path_bytes.size > UInt32::MAX
          raise Error.new("source path too long for index: #{index.source_path}")
        end

        entries_offset = HEADER_SIZE + source_path_bytes.size.to_u64
        name_table_offset = entries_offset + index.entries.size.to_u64 * ENTRY_SIZE
        windows_offset = name_table_offset +
                         index.name_table.size.to_u64 +
                         index.checkpoint_metas.size.to_u64 * CHECKPOINT_META_SIZE

        io.write(MAGIC.to_slice)
        BinaryIO.write_u32(io, VERSION)
        BinaryIO.write_u16(io, 0_u16) # flags, reserved
        BinaryIO.write_u16(io, 0_u16) # header padding
        BinaryIO.write_u64(io, index.source_size)
        BinaryIO.write_i64(io, index.source_mtime)
        BinaryIO.write_u64(io, index.checkpoint_span)
        BinaryIO.write_u8(io, index.hash_algorithm.value)
        BinaryIO.write_u8(io, index.name_mode.value)
        BinaryIO.write_u8(io, index.input_names_sorted? ? 1_u8 : 0_u8)
        BinaryIO.write_u8(io, 0_u8) # padding
        BinaryIO.write_u64(io, index.hash_seed)
        BinaryIO.write_u64(io, index.record_count)
        BinaryIO.write_u64(io, index.checkpoint_metas.size.to_u64)
        BinaryIO.write_u64(io, index.entries.size.to_u64)
        BinaryIO.write_u32(io, source_path_bytes.size.to_u32)
        BinaryIO.write_u64(io, index.name_table.size.to_u64)
        BinaryIO.write_u64(io, entries_offset)
        BinaryIO.write_u64(io, name_table_offset)
        BinaryIO.write_u64(io, windows_offset)
        io.write(source_path_bytes)

        unless io.pos.to_u64 == entries_offset
          raise Error.new("internal index layout error: entry offset mismatch")
        end

        index.entries.each do |entry|
          write_entry(io, entry)
        end

        unless io.pos.to_u64 == name_table_offset
          raise Error.new("internal index layout error: name table offset mismatch")
        end

        io.write(index.name_table)

        index.checkpoint_metas.each do |checkpoint|
          write_checkpoint_meta(io, checkpoint)
        end

        unless io.pos.to_u64 == windows_offset
          raise Error.new("internal index layout error: window offset mismatch")
        end

        index.checkpoint_metas.each_index do |checkpoint_id|
          io.write(index.checkpoint_window(checkpoint_id))
        end
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity
    def read(path : String) : Index
      File.open(path, "rb") do |io|
        magic = Bytes.new(8)
        io.read_fully(magic)
        unless magic[0, 4] == "FQIX".to_slice
          raise Error.new("invalid fqix index magic")
        end
        version = BinaryIO.read_u32(io)
        unless version == VERSION
          raise Error.new("unsupported fqix version #{version}; please rebuild the index")
        end
        unless String.new(magic) == MAGIC
          raise Error.new("invalid fqix index magic")
        end
        flags = BinaryIO.read_u16(io)
        padding = BinaryIO.read_u16(io)
        unless flags == 0 && padding == 0
          raise Error.new("unsupported fqix index header flags")
        end
        source_size = BinaryIO.read_u64(io)
        source_mtime = BinaryIO.read_i64(io)
        checkpoint_span = BinaryIO.read_u64(io)
        hash_algorithm = parse_hash_algorithm(BinaryIO.read_u8(io))
        name_mode = parse_name_mode(BinaryIO.read_u8(io))
        input_names_sorted_byte = BinaryIO.read_u8(io)
        header_padding = BinaryIO.read_u8(io)
        unless (input_names_sorted_byte == 0 || input_names_sorted_byte == 1) && header_padding == 0
          raise Error.new("unsupported fqix index header flags")
        end
        hash_seed = BinaryIO.read_u64(io)
        record_count = BinaryIO.read_u64(io)
        ncheckpoints = BinaryIO.read_u64(io)
        nentries = BinaryIO.read_u64(io)
        source_path_len = BinaryIO.read_u32(io)
        name_table_size = BinaryIO.read_u64(io)
        entries_offset = BinaryIO.read_u64(io)
        name_table_offset = BinaryIO.read_u64(io)
        windows_offset = BinaryIO.read_u64(io)

        file_size = File.size(path).to_u64
        if entries_offset < HEADER_SIZE || name_table_offset < entries_offset || windows_offset < name_table_offset || windows_offset > file_size
          raise Error.new("invalid fqix index section offset")
        end
        if source_path_len.to_u64 > entries_offset - HEADER_SIZE
          raise Error.new("invalid fqix index source path length")
        end

        path_buf = Bytes.new(source_path_len)
        io.read_fully(path_buf)
        source_path = String.new(path_buf)

        unless io.pos.to_u64 == entries_offset
          raise Error.new("invalid fqix index entry offset")
        end

        ensure_table_fits!("entry", nentries, name_table_offset - entries_offset, ENTRY_SIZE)
        entries = Array(Entry).new(nentries.to_i)
        nentries.times do
          entries << read_entry(io)
        end

        if io.pos.to_u64 != name_table_offset
          raise Error.new("invalid fqix index name table offset")
        end
        if name_table_size > MAX_ARRAY_SIZE || name_table_size > windows_offset - name_table_offset
          raise Error.new("invalid fqix index name table size")
        end
        name_table = Bytes.new(name_table_size.to_i)
        io.read_fully(name_table)

        ensure_table_fits!("checkpoint", ncheckpoints, windows_offset - io.pos.to_u64, CHECKPOINT_META_SIZE)
        checkpoint_metas = Array(CheckpointMeta).new(ncheckpoints.to_i)
        ncheckpoints.times do
          checkpoint_metas << read_checkpoint_meta(io)
        end

        if io.pos.to_u64 != windows_offset
          raise Error.new("invalid fqix index window offset")
        end

        Index.new(
          source_path,
          source_size,
          source_mtime,
          checkpoint_span,
          hash_algorithm,
          hash_seed,
          name_mode,
          record_count,
          input_names_sorted_byte == 1,
          checkpoint_metas,
          entries,
          name_table,
          FileWindowStore.new(path, windows_offset),
          version
        )
      end
    end

    private def ensure_table_fits!(table : String, count : UInt64, bytes_available : UInt64, min_entry_size : UInt64) : Nil
      if count > MAX_ARRAY_SIZE || count > bytes_available // min_entry_size
        raise Error.new("invalid fqix index #{table} count")
      end
    end

    private def parse_hash_algorithm(value : UInt8) : HashAlgorithm
      HashAlgorithm.from_value(value)
    rescue
      raise Error.new("unsupported fqix hash algorithm #{value}")
    end

    private def parse_name_mode(value : UInt8) : NameMode
      NameMode.from_value(value)
    rescue
      raise Error.new("unsupported fqix name mode #{value}")
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

    private def write_entry(io : IO, entry : Entry) : Nil
      BinaryIO.write_u64(io, entry.name_hash)
      BinaryIO.write_u64(io, entry.name_offset)
      BinaryIO.write_u32(io, entry.name_length)
      BinaryIO.write_u64(io, entry.record_number)
      BinaryIO.write_u64(io, entry.record_offset)
      BinaryIO.write_u64(io, entry.record_size)
      BinaryIO.write_u32(io, entry.flags)
    end

    private def read_entry(io : IO) : Entry
      name_hash = BinaryIO.read_u64(io)
      name_offset = BinaryIO.read_u64(io)
      name_length = BinaryIO.read_u32(io)
      record_number = BinaryIO.read_u64(io)
      record_offset = BinaryIO.read_u64(io)
      record_size = BinaryIO.read_u64(io)
      flags = BinaryIO.read_u32(io)
      Entry.new(name_hash, name_offset, name_length, record_number, record_offset, record_size, flags)
    end
  end
end
