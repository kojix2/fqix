require "./binary_io"
require "./error"
require "./order"
require "./window_store"

module Fqix
  module IndexFormat
    extend self

    MAGIC_V1 = "FQIX\u{1}\0\0\0"
    MAGIC_V2 = "FQIX\u{2}\0\0\0"
    MAGIC    = MAGIC_V2

    # Format kind = version major (matches the magic byte). Minor is the current
    # revision within each kind; bump it when a kind's layout changes.
    SPARSE_MAJOR = 1_u16
    EXACT_MAJOR  = 2_u16
    SPARSE_MINOR = 1_u16
    EXACT_MINOR  = 0_u16

    SPARSE_VERSION = FormatVersion.new(SPARSE_MAJOR, SPARSE_MINOR)
    EXACT_VERSION  = FormatVersion.new(EXACT_MAJOR, EXACT_MINOR)
    VERSION        = EXACT_VERSION

    V1_0_HEADER_SIZE     =  80_u64
    V1_HEADER_SIZE       =  88_u64
    V2_HEADER_SIZE       = 112_u64
    HEADER_SIZE          = V2_HEADER_SIZE
    CHECKPOINT_META_SIZE = 21_u64
    MIN_NAME_ENTRY_SIZE  = 26_u64
    ENTRY_SIZE           = 48_u64
    MAX_ARRAY_SIZE       = Int32::MAX.to_u64

    def write(index : Index, path : String) : Nil
      case index.mode
      in .sparse?
        write_v1(index, path)
      in .exact?
        write_v2(index, path)
      end
    end

    def read(path : String) : Index
      File.open(path, "rb") do |io|
        magic = Bytes.new(8)
        io.read_fully(magic)
        unless magic[0, 4] == "FQIX".to_slice
          raise Error.new("invalid fqix index magic")
        end
        version = read_version(io)
        case version.major
        when SPARSE_MAJOR
          unless String.new(magic) == MAGIC_V1
            raise Error.new("invalid fqix index magic")
          end
          if version.minor > SPARSE_MINOR
            raise Error.new("unsupported fqix format #{version}; please rebuild the index")
          end
          read_v1_after_version(io, path, version)
        when EXACT_MAJOR
          unless String.new(magic) == MAGIC_V2
            raise Error.new("invalid fqix index magic")
          end
          if version.minor > EXACT_MINOR
            raise Error.new("unsupported fqix format #{version}; please rebuild the index")
          end
          read_v2_after_version(io, path, version)
        else
          raise Error.new("unsupported fqix format #{version}; please rebuild the index")
        end
      end
    end

    # The version field is two little-endian u16 values (major, minor). This is
    # byte-compatible with the older single u32 version field.
    def read_version(io : IO) : FormatVersion
      major = BinaryIO.read_u16(io)
      minor = BinaryIO.read_u16(io)
      FormatVersion.new(major, minor)
    end

    def write_version(io : IO, version : FormatVersion) : Nil
      BinaryIO.write_u16(io, version.major)
      BinaryIO.write_u16(io, version.minor)
    end

    private def write_v1(index : Index, path : String) : Nil
      File.open(path, "wb") do |io|
        source_path_bytes = index.source_path.to_slice
        if source_path_bytes.size > UInt32::MAX
          raise Error.new("source path too long for index: #{index.source_path}")
        end

        windows_offset = V1_HEADER_SIZE +
                         source_path_bytes.size.to_u64 +
                         index.checkpoint_metas.size.to_u64 * CHECKPOINT_META_SIZE +
                         name_table_size(index.names)

        io.write(MAGIC_V1.to_slice)
        write_version(io, SPARSE_VERSION)
        BinaryIO.write_u16(io, 0_u16)
        BinaryIO.write_u16(io, 0_u16)
        BinaryIO.write_u64(io, index.source_size)
        BinaryIO.write_i64(io, index.source_mtime)
        BinaryIO.write_u64(io, index.checkpoint_span)
        BinaryIO.write_u32(io, index.name_interval)
        BinaryIO.write_u32(io, source_path_bytes.size.to_u32)
        BinaryIO.write_u64(io, index.checkpoint_metas.size.to_u64)
        BinaryIO.write_u64(io, index.names.size.to_u64)
        BinaryIO.write_u64(io, windows_offset)
        BinaryIO.write_u64(io, index.record_count)
        BinaryIO.write_u8(io, index.order_mode.value)
        io.write(Bytes.new(7))
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

    private def write_v2(index : Index, path : String) : Nil
      File.open(path, "wb") do |io|
        source_path_bytes = index.source_path.to_slice
        if source_path_bytes.size > UInt32::MAX
          raise Error.new("source path too long for index: #{index.source_path}")
        end

        entries_offset = V2_HEADER_SIZE + source_path_bytes.size.to_u64
        name_table_offset = entries_offset + index.entries.size.to_u64 * ENTRY_SIZE
        windows_offset = name_table_offset +
                         index.name_table.size.to_u64 +
                         index.checkpoint_metas.size.to_u64 * CHECKPOINT_META_SIZE

        io.write(MAGIC_V2.to_slice)
        write_version(io, EXACT_VERSION)
        BinaryIO.write_u16(io, 0_u16)
        BinaryIO.write_u16(io, 0_u16)
        BinaryIO.write_u64(io, index.source_size)
        BinaryIO.write_i64(io, index.source_mtime)
        BinaryIO.write_u64(io, index.checkpoint_span)
        BinaryIO.write_u8(io, index.hash_algorithm.value)
        BinaryIO.write_u8(io, index.name_mode.value)
        BinaryIO.write_u8(io, index.input_names_sorted? ? 1_u8 : 0_u8)
        BinaryIO.write_u8(io, 0_u8)
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

    private def read_v1_after_version(io : IO, path : String, version : FormatVersion) : Index
      flags = BinaryIO.read_u16(io)
      padding = BinaryIO.read_u16(io)
      unless flags == 0 && padding == 0
        raise Error.new("unsupported fqix index header flags")
      end
      source_size = BinaryIO.read_u64(io)
      source_mtime = BinaryIO.read_i64(io)
      checkpoint_span = BinaryIO.read_u64(io)
      name_interval = BinaryIO.read_u32(io)
      source_path_len = BinaryIO.read_u32(io)
      ncheckpoints = BinaryIO.read_u64(io)
      nnames = BinaryIO.read_u64(io)
      windows_offset = BinaryIO.read_u64(io)
      record_count = BinaryIO.read_u64(io)
      order_mode = read_v1_order_mode(io, version)
      header_size = version.minor == 0 ? V1_0_HEADER_SIZE : V1_HEADER_SIZE

      file_size = File.size(path).to_u64
      if windows_offset > file_size || windows_offset < header_size
        raise Error.new("invalid fqix index window offset")
      end
      if source_path_len.to_u64 > windows_offset - header_size
        raise Error.new("invalid fqix index source path length")
      end

      path_buf = Bytes.new(source_path_len)
      io.read_fully(path_buf)
      source_path = String.new(path_buf)

      bytes_to_windows = windows_offset - io.pos.to_u64
      ensure_table_fits!("checkpoint", ncheckpoints, bytes_to_windows, CHECKPOINT_META_SIZE)
      checkpoint_metas = Array(CheckpointMeta).new(ncheckpoints.to_i)
      ncheckpoints.times do
        checkpoint_metas << read_checkpoint_meta(io)
      end

      bytes_to_windows = windows_offset - io.pos.to_u64
      ensure_table_fits!("name", nnames, bytes_to_windows, MIN_NAME_ENTRY_SIZE)
      names = Array(NameEntry).new(nnames.to_i)
      nnames.times do
        names << read_name_entry(io, windows_offset)
      end
      validate_sparse_name_entries!(names, checkpoint_metas)

      if io.pos.to_u64 != windows_offset
        raise Error.new("invalid fqix index window offset")
      end
      ensure_windows_fit!(ncheckpoints, windows_offset, file_size)

      Index.new(
        source_path,
        source_size,
        source_mtime,
        checkpoint_span,
        IndexMode::Sparse,
        name_interval,
        order_mode,
        Index::DEFAULT_HASH_ALGORITHM,
        Index::DEFAULT_HASH_SEED,
        Index::DEFAULT_NAME_MODE,
        record_count,
        true,
        checkpoint_metas,
        names,
        [] of Entry,
        Bytes.empty,
        FileWindowStore.new(path, windows_offset),
        version
      )
    end

    private def read_v1_order_mode(io : IO, version : FormatVersion) : OrderMode
      return OrderMode::Lexicographic if version.minor == 0

      order_mode = parse_order_mode(BinaryIO.read_u8(io))
      reserved = Bytes.new(7)
      io.read_fully(reserved)
      unless reserved.all?(&.zero?)
        raise Error.new("unsupported fqix sparse order header flags")
      end
      order_mode
    end

    private def read_v2_after_version(io : IO, path : String, version : FormatVersion) : Index
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
      validate_v2_offsets!(source_path_len, entries_offset, name_table_offset, windows_offset, file_size)

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

      name_table = read_v2_name_table(io, name_table_size, name_table_offset, windows_offset)
      checkpoint_metas = read_checkpoint_metas(io, ncheckpoints, windows_offset)

      if io.pos.to_u64 != windows_offset
        raise Error.new("invalid fqix index window offset")
      end
      ensure_windows_fit!(ncheckpoints, windows_offset, file_size)

      Index.new(
        source_path,
        source_size,
        source_mtime,
        checkpoint_span,
        IndexMode::Exact,
        0_u32,
        Index::DEFAULT_ORDER_MODE,
        hash_algorithm,
        hash_seed,
        name_mode,
        record_count,
        input_names_sorted_byte == 1,
        checkpoint_metas,
        [] of NameEntry,
        entries,
        name_table,
        FileWindowStore.new(path, windows_offset),
        version
      )
    end

    private def validate_v2_offsets!(source_path_len : UInt32,
                                     entries_offset : UInt64,
                                     name_table_offset : UInt64,
                                     windows_offset : UInt64,
                                     file_size : UInt64) : Nil
      if entries_offset < V2_HEADER_SIZE || name_table_offset < entries_offset || windows_offset < name_table_offset || windows_offset > file_size
        raise Error.new("invalid fqix index section offset")
      end
      if source_path_len.to_u64 > entries_offset - V2_HEADER_SIZE
        raise Error.new("invalid fqix index source path length")
      end
    end

    private def read_v2_name_table(io : IO,
                                   name_table_size : UInt64,
                                   name_table_offset : UInt64,
                                   windows_offset : UInt64) : Bytes
      if io.pos.to_u64 != name_table_offset
        raise Error.new("invalid fqix index name table offset")
      end
      if name_table_size > MAX_ARRAY_SIZE || name_table_size > windows_offset - name_table_offset
        raise Error.new("invalid fqix index name table size")
      end

      name_table = Bytes.new(name_table_size.to_i)
      io.read_fully(name_table)
      name_table
    end

    private def read_checkpoint_metas(io : IO, ncheckpoints : UInt64, windows_offset : UInt64) : Array(CheckpointMeta)
      ensure_table_fits!("checkpoint", ncheckpoints, windows_offset - io.pos.to_u64, CHECKPOINT_META_SIZE)
      checkpoint_metas = Array(CheckpointMeta).new(ncheckpoints.to_i)
      ncheckpoints.times do
        checkpoint_metas << read_checkpoint_meta(io)
      end
      checkpoint_metas
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

    private def ensure_table_fits!(table : String, count : UInt64, bytes_available : UInt64, min_entry_size : UInt64) : Nil
      if count > MAX_ARRAY_SIZE || count > bytes_available // min_entry_size
        raise Error.new("invalid fqix index #{table} count")
      end
    end

    private def ensure_windows_fit!(ncheckpoints : UInt64, windows_offset : UInt64, file_size : UInt64) : Nil
      bytes_available = file_size - windows_offset
      window_size = Zran::WINDOW_SIZE.to_u64
      if ncheckpoints > MAX_ARRAY_SIZE || ncheckpoints > bytes_available // window_size
        raise Error.new("invalid fqix index window section")
      end
    end

    private def validate_sparse_name_entries!(names : Array(NameEntry), checkpoint_metas : Array(CheckpointMeta)) : Nil
      names.each do |entry|
        if entry.checkpoint_id >= checkpoint_metas.size.to_u64
          raise Error.new("invalid fqix sparse name checkpoint reference")
        end

        checkpoint = checkpoint_metas[entry.checkpoint_id.to_i]
        if entry.uncompressed_offset < checkpoint.out_offset
          raise Error.new("invalid fqix sparse name checkpoint reference")
        end
        if entry.delta != entry.uncompressed_offset - checkpoint.out_offset
          raise Error.new("invalid fqix sparse name checkpoint reference")
        end
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

    private def parse_order_mode(value : UInt8) : OrderMode
      OrderMode.from_value(value)
    rescue
      raise Error.new("unsupported fqix order mode #{value}")
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
      raise Error.new("invalid fqix checkpoint bits") if bits > 7
      raise Error.new("invalid fqix checkpoint dictionary size") if have > Zran::WINDOW_SIZE
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

    private def read_name_entry(io : IO, windows_offset : UInt64) : NameEntry
      if io.pos.to_u64 + 2_u64 > windows_offset
        raise Error.new("invalid fqix index name table")
      end
      len = BinaryIO.read_u16(io)
      bytes_needed = len.to_u64 + 8_u64 + 8_u64 + 8_u64
      if bytes_needed > windows_offset - io.pos.to_u64
        raise Error.new("invalid fqix index name table")
      end
      buf = Bytes.new(len)
      io.read_fully(buf)
      name = String.new(buf)
      uncompressed_offset = BinaryIO.read_u64(io)
      checkpoint_id = BinaryIO.read_u64(io)
      delta = BinaryIO.read_u64(io)
      NameEntry.new(name, uncompressed_offset, checkpoint_id, delta)
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
