require "./binary_io"
require "./error"
require "./order"
require "./window_store"
require "compress/deflate"

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
    SPARSE_MINOR = 2_u16
    EXACT_MINOR  = 3_u16

    SPARSE_VERSION = FormatVersion.new(SPARSE_MAJOR, SPARSE_MINOR)
    EXACT_VERSION  = FormatVersion.new(EXACT_MAJOR, EXACT_MINOR)
    VERSION        = EXACT_VERSION

    V1_0_HEADER_SIZE            =  80_u64
    V1_HEADER_SIZE              =  88_u64
    V2_1_HEADER_SIZE            = 112_u64
    V2_2_HEADER_SIZE            = 128_u64
    V2_HEADER_SIZE              = V2_1_HEADER_SIZE
    HEADER_SIZE                 = V2_1_HEADER_SIZE
    LEGACY_CHECKPOINT_META_SIZE = 21_u64
    CHECKPOINT_META_SIZE        = 25_u64
    MIN_NAME_ENTRY_SIZE         = 26_u64
    ENTRY_SIZE                  = 20_u64
    SLOT_SIZE                   = 14_u64
    OVERFLOW_ENTRY_SIZE         = 13_u64
    MAX_ARRAY_SIZE              = Int32::MAX.to_u64
    MAX_COMPRESSED_WINDOW_SIZE  = Zran::WINDOW_SIZE.to_u64 + 64_u64

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
          if version.minor == 0
            raise Error.new("unsupported fqix format #{version}; please rebuild the index")
          elsif version.minor > EXACT_MINOR
            raise Error.new("unsupported fqix format #{version}; please rebuild the index")
          end
          case version.minor
          when 1
            read_v2_1_after_version(io, path, version)
          when 2, 3
            read_v2_2_after_version(io, path, version)
          else
            raise Error.new("unsupported fqix format #{version}; please rebuild the index")
          end
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

        compressed_windows = compress_checkpoint_windows(index)
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

        index.checkpoint_metas.each_with_index do |checkpoint, checkpoint_id|
          write_checkpoint_meta(io, checkpoint, compressed_windows[checkpoint_id].size.to_u32)
        end

        index.names.each do |entry|
          write_name_entry(io, entry)
        end

        unless io.pos.to_u64 == windows_offset
          raise Error.new("internal index layout error: window offset mismatch")
        end

        compressed_windows.each do |window|
          io.write(window)
        end
      end
    end

    private def write_v2(index : Index, path : String) : Nil
      File.open(path, "wb") do |io|
        source_path_bytes = index.source_path.to_slice
        if source_path_bytes.size > UInt32::MAX
          raise Error.new("source path too long for index: #{index.source_path}")
        end

        compressed_windows = compress_checkpoint_windows(index)
        mphf = index.mphf || Mphf.empty(index.fingerprint_seed)
        mphf_blob = mphf.to_slice
        mphf_offset = V2_2_HEADER_SIZE + source_path_bytes.size.to_u64
        slots_offset = mphf_offset + mphf_blob.size.to_u64
        overflows_offset = slots_offset + index.slots.size.to_u64 * SLOT_SIZE
        checkpoints_offset = overflows_offset + index.overflows.size.to_u64 * OVERFLOW_ENTRY_SIZE
        windows_offset = checkpoints_offset +
                         index.checkpoint_metas.size.to_u64 * CHECKPOINT_META_SIZE

        io.write(MAGIC_V2.to_slice)
        write_version(io, EXACT_VERSION)
        BinaryIO.write_u16(io, 0_u16)
        BinaryIO.write_u16(io, 0_u16)
        BinaryIO.write_u64(io, index.source_size)
        BinaryIO.write_i64(io, index.source_mtime)
        BinaryIO.write_u64(io, index.checkpoint_span)
        BinaryIO.write_u8(io, index.fingerprint_algorithm.value)
        BinaryIO.write_u8(io, index.name_mode.value)
        BinaryIO.write_u8(io, index.input_names_sorted? ? 1_u8 : 0_u8)
        BinaryIO.write_u8(io, 0_u8)
        BinaryIO.write_u64(io, index.fingerprint_seed)
        BinaryIO.write_u64(io, index.record_count)
        BinaryIO.write_u64(io, index.checkpoint_metas.size.to_u64)
        BinaryIO.write_u64(io, index.slots.size.to_u64)
        BinaryIO.write_u32(io, source_path_bytes.size.to_u32)
        BinaryIO.write_u64(io, mphf_offset)
        BinaryIO.write_u64(io, slots_offset)
        BinaryIO.write_u64(io, overflows_offset)
        BinaryIO.write_u64(io, checkpoints_offset)
        BinaryIO.write_u64(io, windows_offset)
        io.write(Bytes.new(8))
        io.write(source_path_bytes)

        unless io.pos.to_u64 == mphf_offset
          raise Error.new("internal index layout error: mphf offset mismatch")
        end

        io.write(mphf_blob)

        unless io.pos.to_u64 == slots_offset
          raise Error.new("internal index layout error: slot offset mismatch")
        end

        index.slots.each do |slot|
          write_slot(io, slot)
        end

        unless io.pos.to_u64 == overflows_offset
          raise Error.new("internal index layout error: overflow offset mismatch")
        end

        index.overflows.each do |entry|
          write_overflow_entry(io, entry)
        end

        index.checkpoint_metas.each_with_index do |checkpoint, checkpoint_id|
          write_checkpoint_meta(io, checkpoint, compressed_windows[checkpoint_id].size.to_u32)
        end

        unless io.pos.to_u64 == windows_offset
          raise Error.new("internal index layout error: window offset mismatch")
        end

        compressed_windows.each do |window|
          io.write(window)
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
      checkpoint_meta_size = checkpoint_meta_size(version)
      compressed_windows = compressed_windows?(version)
      ensure_table_fits!("checkpoint", ncheckpoints, bytes_to_windows, checkpoint_meta_size)
      checkpoint_metas = Array(CheckpointMeta).new(ncheckpoints.to_i)
      window_compressed_sizes = Array(UInt32).new(ncheckpoints.to_i)
      ncheckpoints.times do
        meta, window_compressed_size = read_checkpoint_meta(io, compressed_windows)
        checkpoint_metas << meta
        window_compressed_sizes << window_compressed_size
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
      window_store = build_window_store(path, windows_offset, file_size, checkpoint_metas, window_compressed_sizes, compressed_windows)

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
        window_store,
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

    private def read_v2_1_after_version(io : IO, path : String, version : FormatVersion) : Index
      flags = BinaryIO.read_u16(io)
      padding = BinaryIO.read_u16(io)
      unless flags == 0 && padding == 0
        raise Error.new("unsupported fqix index header flags")
      end
      source_size = BinaryIO.read_u64(io)
      source_mtime = BinaryIO.read_i64(io)
      checkpoint_span = BinaryIO.read_u64(io)
      fingerprint_algorithm = parse_hash_algorithm(BinaryIO.read_u8(io))
      name_mode = parse_name_mode(BinaryIO.read_u8(io))
      input_names_sorted_byte = BinaryIO.read_u8(io)
      header_padding = BinaryIO.read_u8(io)
      unless (input_names_sorted_byte == 0 || input_names_sorted_byte == 1) && header_padding == 0
        raise Error.new("unsupported fqix index header flags")
      end
      fingerprint_seed = BinaryIO.read_u64(io)
      record_count = BinaryIO.read_u64(io)
      ncheckpoints = BinaryIO.read_u64(io)
      nentries = BinaryIO.read_u64(io)
      source_path_len = BinaryIO.read_u32(io)
      entries_offset = BinaryIO.read_u64(io)
      checkpoints_offset = BinaryIO.read_u64(io)
      windows_offset = BinaryIO.read_u64(io)
      reserved_tail = Bytes.new(8)
      io.read_fully(reserved_tail)
      unless reserved_tail.all?(&.zero?)
        raise Error.new("unsupported fqix index header flags")
      end

      file_size = File.size(path).to_u64
      validate_v2_offsets!(source_path_len, entries_offset, checkpoints_offset, windows_offset, file_size)

      path_buf = Bytes.new(source_path_len)
      io.read_fully(path_buf)
      source_path = String.new(path_buf)

      unless io.pos.to_u64 == entries_offset
        raise Error.new("invalid fqix index entry offset")
      end

      ensure_exact_table_size!("entry", nentries, checkpoints_offset - entries_offset, ENTRY_SIZE)
      entries = Array(Entry).new(nentries.to_i)
      nentries.times do
        entries << read_entry(io)
      end
      validate_exact_entries!(entries)

      checkpoint_metas, window_compressed_sizes = read_checkpoint_metas(io, ncheckpoints, windows_offset, version)

      if io.pos.to_u64 != windows_offset
        raise Error.new("invalid fqix index window offset")
      end
      window_store = build_window_store(path, windows_offset, file_size, checkpoint_metas, window_compressed_sizes, compressed_windows?(version))

      Index.new(
        source_path,
        source_size,
        source_mtime,
        checkpoint_span,
        IndexMode::Exact,
        0_u32,
        Index::DEFAULT_ORDER_MODE,
        fingerprint_algorithm,
        fingerprint_seed,
        name_mode,
        record_count,
        input_names_sorted_byte == 1,
        checkpoint_metas,
        [] of NameEntry,
        entries,
        window_store,
        version,
        nil,
        [] of ExactSlot,
        [] of ExactOverflowEntry
      )
    end

    private def read_v2_2_after_version(io : IO, path : String, version : FormatVersion) : Index
      flags = BinaryIO.read_u16(io)
      padding = BinaryIO.read_u16(io)
      unless flags == 0 && padding == 0
        raise Error.new("unsupported fqix index header flags")
      end
      source_size = BinaryIO.read_u64(io)
      source_mtime = BinaryIO.read_i64(io)
      checkpoint_span = BinaryIO.read_u64(io)
      fingerprint_algorithm = parse_hash_algorithm(BinaryIO.read_u8(io))
      name_mode = parse_name_mode(BinaryIO.read_u8(io))
      input_names_sorted_byte = BinaryIO.read_u8(io)
      header_padding = BinaryIO.read_u8(io)
      unless (input_names_sorted_byte == 0 || input_names_sorted_byte == 1) && header_padding == 0
        raise Error.new("unsupported fqix index header flags")
      end
      fingerprint_seed = BinaryIO.read_u64(io)
      record_count = BinaryIO.read_u64(io)
      ncheckpoints = BinaryIO.read_u64(io)
      nslots = BinaryIO.read_u64(io)
      source_path_len = BinaryIO.read_u32(io)
      mphf_offset = BinaryIO.read_u64(io)
      slots_offset = BinaryIO.read_u64(io)
      overflows_offset = BinaryIO.read_u64(io)
      checkpoints_offset = BinaryIO.read_u64(io)
      windows_offset = BinaryIO.read_u64(io)
      reserved_tail = Bytes.new(8)
      io.read_fully(reserved_tail)
      unless reserved_tail.all?(&.zero?)
        raise Error.new("unsupported fqix index header flags")
      end

      file_size = File.size(path).to_u64
      validate_v2_2_offsets!(source_path_len, mphf_offset, slots_offset, overflows_offset, checkpoints_offset, windows_offset, file_size)

      path_buf = Bytes.new(source_path_len)
      io.read_fully(path_buf)
      source_path = String.new(path_buf)

      unless io.pos.to_u64 == mphf_offset
        raise Error.new("invalid fqix index mphf offset")
      end
      mphf = Mphf.read(io, slots_offset - mphf_offset, fingerprint_seed)
      unless mphf.key_count == nslots
        raise Error.new("invalid fqix mphf key count")
      end

      ensure_exact_table_size!("slot", nslots, overflows_offset - slots_offset, SLOT_SIZE)
      slots = Array(ExactSlot).new(nslots.to_i)
      nslots.times do
        slots << read_slot(io)
      end

      overflow_count = (checkpoints_offset - overflows_offset) // OVERFLOW_ENTRY_SIZE
      ensure_exact_table_size!("overflow", overflow_count, checkpoints_offset - overflows_offset, OVERFLOW_ENTRY_SIZE)
      overflows = Array(ExactOverflowEntry).new(overflow_count.to_i)
      overflow_count.times do
        overflows << read_overflow_entry(io)
      end
      validate_exact_slots!(slots, overflows)

      checkpoint_metas, window_compressed_sizes = read_checkpoint_metas(io, ncheckpoints, windows_offset, version)

      if io.pos.to_u64 != windows_offset
        raise Error.new("invalid fqix index window offset")
      end
      window_store = build_window_store(path, windows_offset, file_size, checkpoint_metas, window_compressed_sizes, compressed_windows?(version))

      Index.new(
        source_path,
        source_size,
        source_mtime,
        checkpoint_span,
        IndexMode::Exact,
        0_u32,
        Index::DEFAULT_ORDER_MODE,
        fingerprint_algorithm,
        fingerprint_seed,
        name_mode,
        record_count,
        input_names_sorted_byte == 1,
        checkpoint_metas,
        [] of NameEntry,
        [] of Entry,
        window_store,
        version,
        mphf,
        slots,
        overflows
      )
    end

    private def validate_v2_offsets!(source_path_len : UInt32,
                                     entries_offset : UInt64,
                                     checkpoints_offset : UInt64,
                                     windows_offset : UInt64,
                                     file_size : UInt64) : Nil
      if entries_offset < V2_HEADER_SIZE || checkpoints_offset < entries_offset || windows_offset < checkpoints_offset || windows_offset > file_size
        raise Error.new("invalid fqix index section offset")
      end
      if source_path_len.to_u64 > entries_offset - V2_HEADER_SIZE
        raise Error.new("invalid fqix index source path length")
      end
    end

    private def validate_v2_2_offsets!(source_path_len : UInt32,
                                       mphf_offset : UInt64,
                                       slots_offset : UInt64,
                                       overflows_offset : UInt64,
                                       checkpoints_offset : UInt64,
                                       windows_offset : UInt64,
                                       file_size : UInt64) : Nil
      if mphf_offset < V2_2_HEADER_SIZE ||
         slots_offset < mphf_offset ||
         overflows_offset < slots_offset ||
         checkpoints_offset < overflows_offset ||
         windows_offset < checkpoints_offset ||
         windows_offset > file_size
        raise Error.new("invalid fqix index section offset")
      end
      if source_path_len.to_u64 > mphf_offset - V2_2_HEADER_SIZE
        raise Error.new("invalid fqix index source path length")
      end
    end

    private def read_checkpoint_metas(io : IO, ncheckpoints : UInt64, windows_offset : UInt64, version : FormatVersion) : Tuple(Array(CheckpointMeta), Array(UInt32))
      compressed_windows = compressed_windows?(version)
      ensure_table_fits!("checkpoint", ncheckpoints, windows_offset - io.pos.to_u64, checkpoint_meta_size(version))
      checkpoint_metas = Array(CheckpointMeta).new(ncheckpoints.to_i)
      window_compressed_sizes = Array(UInt32).new(ncheckpoints.to_i)
      ncheckpoints.times do
        meta, window_compressed_size = read_checkpoint_meta(io, compressed_windows)
        checkpoint_metas << meta
        window_compressed_sizes << window_compressed_size
      end
      {checkpoint_metas, window_compressed_sizes}
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

    private def ensure_exact_table_size!(table : String, count : UInt64, bytes_available : UInt64, entry_size : UInt64) : Nil
      ensure_table_fits!(table, count, bytes_available, entry_size)
      unless count * entry_size == bytes_available
        raise Error.new("invalid fqix index section offset")
      end
    end

    private def ensure_raw_windows_fit!(ncheckpoints : UInt64, windows_offset : UInt64, file_size : UInt64) : Nil
      bytes_available = file_size - windows_offset
      window_size = Zran::WINDOW_SIZE.to_u64
      if ncheckpoints > MAX_ARRAY_SIZE || ncheckpoints > bytes_available // window_size
        raise Error.new("invalid fqix index window section")
      end
    end

    private def build_window_store(path : String,
                                   windows_offset : UInt64,
                                   file_size : UInt64,
                                   checkpoint_metas : Array(CheckpointMeta),
                                   window_compressed_sizes : Array(UInt32),
                                   compressed_windows : Bool) : WindowStore
      unless compressed_windows
        ensure_raw_windows_fit!(checkpoint_metas.size.to_u64, windows_offset, file_size)
        return FileWindowStore.new(path, windows_offset)
      end

      descriptors = build_compressed_window_descriptors(checkpoint_metas, window_compressed_sizes, file_size - windows_offset)
      CompressedFileWindowStore.new(path, windows_offset, descriptors)
    end

    private def build_compressed_window_descriptors(checkpoint_metas : Array(CheckpointMeta),
                                                    window_compressed_sizes : Array(UInt32),
                                                    bytes_available : UInt64) : Array(CompressedWindowDescriptor)
      if checkpoint_metas.size > MAX_ARRAY_SIZE || checkpoint_metas.size != window_compressed_sizes.size
        raise Error.new("invalid fqix index window section")
      end

      rel_offset = 0_u64
      descriptors = Array(CompressedWindowDescriptor).new(checkpoint_metas.size)
      checkpoint_metas.each_with_index do |meta, index|
        compressed_size = window_compressed_sizes[index]
        validate_window_compressed_size!(meta.have, compressed_size)
        if rel_offset > bytes_available || compressed_size.to_u64 > bytes_available - rel_offset
          raise Error.new("invalid fqix index window section")
        end
        descriptors << CompressedWindowDescriptor.new(rel_offset, compressed_size, meta.have)
        rel_offset += compressed_size.to_u64
      end

      unless rel_offset == bytes_available
        raise Error.new("invalid fqix index window section")
      end
      descriptors
    end

    private def validate_window_compressed_size!(have : UInt32, compressed_size : UInt32) : Nil
      if have == 0
        raise Error.new("invalid fqix compressed checkpoint window length") unless compressed_size == 0
      elsif compressed_size == 0 || compressed_size.to_u64 > MAX_COMPRESSED_WINDOW_SIZE
        raise Error.new("invalid fqix compressed checkpoint window length")
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

    private def validate_exact_entries!(entries : Array(Entry)) : Nil
      previous = nil.as(Entry?)
      entries.each do |entry|
        if prev = previous
          if entry.fingerprint < prev.fingerprint || (entry.fingerprint == prev.fingerprint && entry.record_offset < prev.record_offset)
            raise Error.new("invalid fqix index entry order")
          end
        end
        previous = entry
      end
    end

    private def validate_exact_slots!(slots : Array(ExactSlot), overflows : Array(ExactOverflowEntry)) : Nil
      slots.each do |slot|
        unless slot.flags == 0 || slot.flags == ExactSlot::FLAG_OVERFLOW
          raise Error.new("unsupported fqix exact slot flags")
        end
        next unless slot.overflow?

        if slot.guard != 0 || slot.overflow_offset + slot.overflow_count.to_u64 > overflows.size.to_u64
          raise Error.new("invalid fqix exact overflow reference")
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

    private def write_checkpoint_meta(io : IO, checkpoint : CheckpointMeta, window_compressed_size : UInt32) : Nil
      BinaryIO.write_u64(io, checkpoint.out_offset)
      BinaryIO.write_u64(io, checkpoint.in_offset)
      BinaryIO.write_u8(io, checkpoint.bits)
      BinaryIO.write_u32(io, checkpoint.have)
      BinaryIO.write_u32(io, window_compressed_size)
    end

    private def read_checkpoint_meta(io : IO, compressed_window : Bool) : Tuple(CheckpointMeta, UInt32)
      out_offset = BinaryIO.read_u64(io)
      in_offset = BinaryIO.read_u64(io)
      bits = BinaryIO.read_u8(io)
      have = BinaryIO.read_u32(io)
      raise Error.new("invalid fqix checkpoint bits") if bits > 7
      raise Error.new("invalid fqix checkpoint dictionary size") if have > Zran::WINDOW_SIZE
      window_compressed_size = compressed_window ? BinaryIO.read_u32(io) : Zran::WINDOW_SIZE.to_u32
      {CheckpointMeta.new(out_offset, in_offset, bits, have), window_compressed_size}
    end

    private def checkpoint_meta_size(version : FormatVersion) : UInt64
      compressed_windows?(version) ? CHECKPOINT_META_SIZE : LEGACY_CHECKPOINT_META_SIZE
    end

    private def compressed_windows?(version : FormatVersion) : Bool
      (version.major == SPARSE_MAJOR && version.minor >= 2) ||
        (version.major == EXACT_MAJOR && version.minor >= 3)
    end

    private def compress_checkpoint_windows(index : Index) : Array(Bytes)
      index.checkpoint_metas.map_with_index do |checkpoint, checkpoint_id|
        have = checkpoint.have
        if have == 0
          Bytes.empty
        else
          window = index.checkpoint_window(checkpoint_id)
          if window.size < have
            raise Error.new("internal index window shorter than checkpoint dictionary")
          end
          output = IO::Memory.new
          Compress::Deflate::Writer.open(output, level: Compress::Deflate::BEST_COMPRESSION) do |deflater|
            deflater.write(window[0, have])
          end
          output.to_slice
        end
      end
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
      BinaryIO.write_u64(io, entry.fingerprint)
      BinaryIO.write_u64(io, entry.record_offset)
      BinaryIO.write_u32(io, entry.record_size)
    end

    private def read_entry(io : IO) : Entry
      fingerprint = BinaryIO.read_u64(io)
      record_offset = BinaryIO.read_u64(io)
      record_size = BinaryIO.read_u32(io)
      Entry.new(fingerprint, record_offset, record_size)
    end

    private def write_slot(io : IO, slot : ExactSlot) : Nil
      BinaryIO.write_u64(io, slot.value)
      BinaryIO.write_u32(io, slot.count_or_size)
      BinaryIO.write_u8(io, slot.guard)
      BinaryIO.write_u8(io, slot.flags)
    end

    private def read_slot(io : IO) : ExactSlot
      value = BinaryIO.read_u64(io)
      count_or_size = BinaryIO.read_u32(io)
      guard = BinaryIO.read_u8(io)
      flags = BinaryIO.read_u8(io)
      ExactSlot.new(value, count_or_size, guard, flags)
    end

    private def write_overflow_entry(io : IO, entry : ExactOverflowEntry) : Nil
      BinaryIO.write_u64(io, entry.record_offset)
      BinaryIO.write_u32(io, entry.record_size)
      BinaryIO.write_u8(io, entry.guard)
    end

    private def read_overflow_entry(io : IO) : ExactOverflowEntry
      record_offset = BinaryIO.read_u64(io)
      record_size = BinaryIO.read_u32(io)
      guard = BinaryIO.read_u8(io)
      ExactOverflowEntry.new(record_offset, record_size, guard)
    end
  end
end
