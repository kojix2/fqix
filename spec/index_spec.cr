require "./spec_helper"

module SpecIndexSupport
  extend self

  def write_gzip_member(path : String, records : Array(Tuple(String, String)), append : Bool = false)
    write_gzip_text_member(path, records.map(&.[1]).join, append)
  end

  def write_gzip_text_member(path : String, text : String, append : Bool = false)
    File.open(path, append ? "ab" : "wb") do |file|
      Compress::Gzip::Writer.open(file) do |gzip|
        gzip << text
      end
    end
  end

  def parse_fastq_text(text : String) : Array(String)
    records = [] of String
    record = IO::Memory.new
    parser = Fqix::Fastq::StreamParser.new(
      ->(segment : Bytes, _line_in_record : Int32, _line_start : UInt64) {
        record.write(segment)
      },
      ->(_record_start : UInt64, _record_size : UInt64) {
        records << record.to_s
        record.clear
        true
      }
    )
    parser.feed(text.to_slice)
    parser.finish
    records
  end

  def write_index_with_version(path : String, major : UInt16, minor : UInt16 = 0_u16)
    File.open(path, "wb") do |io|
      io.write(Fqix::Index::MAGIC.to_slice)
      Fqix::IndexFormat.write_version(io, Fqix::FormatVersion.new(major, minor))
    end
  end

  def write_index_header(path : String,
                         source_path_len : UInt32 = 0_u32,
                         ncheckpoints : UInt64 = 0_u64,
                         nnames : UInt64 = 0_u64,
                         windows_offset : UInt64 = Fqix::IndexFormat::HEADER_SIZE,
                         flags : UInt16 = 0_u16,
                         padding : UInt16 = 0_u16)
    File.open(path, "wb") do |io|
      io.write(Fqix::IndexFormat::MAGIC.to_slice)
      Fqix::IndexFormat.write_version(io, Fqix::IndexFormat::EXACT_VERSION)
      name_table_offset =
        if nnames > UInt64::MAX // Fqix::IndexFormat::ENTRY_SIZE
          Fqix::IndexFormat::HEADER_SIZE + source_path_len
        else
          Fqix::IndexFormat::HEADER_SIZE + source_path_len + nnames * Fqix::IndexFormat::ENTRY_SIZE
        end
      Fqix::BinaryIO.write(io) do
        u16 flags
        u16 padding
        u64 0_u64
        i64 0_i64
        u64 1_u64
        u8 Fqix::HashAlgorithm::Fnv1a64.value
        u8 Fqix::NameMode::FirstToken.value
        u8 1_u8
        u8 0_u8
        u64 0_u64
        u64 0_u64
        u64 ncheckpoints
        u64 nnames
        u32 source_path_len
        u64 0_u64
        u64 Fqix::IndexFormat::HEADER_SIZE + source_path_len
        u64 name_table_offset
        u64 windows_offset
      end
    end
  end

  def write_exact_index_with_checkpoint_meta(path : String,
                                             bits : UInt8 = 0_u8,
                                             have : UInt32 = 0_u32,
                                             window_bytes : Int32 = Fqix::Zran::WINDOW_SIZE)
    windows_offset = Fqix::IndexFormat::V2_HEADER_SIZE + Fqix::IndexFormat::CHECKPOINT_META_SIZE
    File.open(path, "wb") do |io|
      io.write(Fqix::IndexFormat::MAGIC.to_slice)
      Fqix::IndexFormat.write_version(io, Fqix::IndexFormat::EXACT_VERSION)
      Fqix::BinaryIO.write(io) do
        u16 0_u16
        u16 0_u16
        u64 0_u64
        i64 0_i64
        u64 1_u64
        u8 Fqix::HashAlgorithm::Fnv1a64.value
        u8 Fqix::NameMode::FirstToken.value
        u8 1_u8
        u8 0_u8
        u64 0_u64
        u64 0_u64
        u64 1_u64
        u64 0_u64
        u32 0_u32
        u64 0_u64
        u64 Fqix::IndexFormat::V2_HEADER_SIZE
        u64 Fqix::IndexFormat::V2_HEADER_SIZE
        u64 windows_offset
        u64 0_u64
        u64 0_u64
        u8 bits
        u32 have
        bytes Bytes.new(window_bytes)
      end
    end
  end

  def write_exact_index_with_entry_flags(path : String, flags : UInt32)
    entry = Fqix::Entry.new(0_u64, 0_u64, 0_u32, 0_u64, 0_u64, 0_u64, flags)
    write_exact_index_with_entries(path, [entry])
  end

  def write_exact_index_with_entries(path : String, entries : Array(Fqix::Entry), name_table : Bytes = Bytes.empty)
    entries_offset = Fqix::IndexFormat::V2_HEADER_SIZE
    name_table_offset = entries_offset + entries.size.to_u64 * Fqix::IndexFormat::ENTRY_SIZE
    windows_offset = name_table_offset + name_table.size.to_u64
    File.open(path, "wb") do |io|
      io.write(Fqix::IndexFormat::MAGIC.to_slice)
      Fqix::IndexFormat.write_version(io, Fqix::IndexFormat::EXACT_VERSION)
      Fqix::BinaryIO.write(io) do
        u16 0_u16
        u16 0_u16
        u64 0_u64
        i64 0_i64
        u64 1_u64
        u8 Fqix::HashAlgorithm::Fnv1a64.value
        u8 Fqix::NameMode::FirstToken.value
        u8 1_u8
        u8 0_u8
        u64 0_u64
        u64 entries.size.to_u64
        u64 0_u64
        u64 entries.size.to_u64
        u32 0_u32
        u64 name_table.size.to_u64
        u64 entries_offset
        u64 name_table_offset
        u64 windows_offset
      end
      entries.each do |entry|
        Fqix::BinaryIO.write(io) do
          u64 entry.name_hash
          u64 entry.name_offset
          u32 entry.name_length
          u64 entry.record_number
          u64 entry.record_offset
          u64 entry.record_size
          u32 entry.flags
        end
      end
      io.write(name_table)
    end
  end

  def write_sparse_v1_index(path : String,
                            source_path : String,
                            checkpoint_metas : Array(Fqix::CheckpointMeta),
                            names : Array(Fqix::NameEntry),
                            windows : Array(Bytes),
                            source_size : UInt64 = 0_u64,
                            source_mtime : Int64 = 0_i64,
                            checkpoint_span : UInt64 = 1_u64,
                            name_interval : UInt32 = 1_u32,
                            record_count : UInt64 = 0_u64)
    File.open(path, "wb") do |io|
      source_path_bytes = source_path.to_slice
      name_table_size = names.sum(0_u64) { |entry| 2_u64 + entry.name.bytesize.to_u64 + 24_u64 }
      windows_offset = Fqix::IndexFormat::V1_0_HEADER_SIZE +
                       source_path_bytes.size.to_u64 +
                       checkpoint_metas.size.to_u64 * Fqix::IndexFormat::CHECKPOINT_META_SIZE +
                       name_table_size

      io.write(Fqix::IndexFormat::MAGIC_V1.to_slice)
      Fqix::IndexFormat.write_version(io, Fqix::FormatVersion.new(Fqix::IndexFormat::SPARSE_MAJOR, 0_u16))
      Fqix::BinaryIO.write(io) do
        u16 0_u16
        u16 0_u16
        u64 source_size
        i64 source_mtime
        u64 checkpoint_span
        u32 name_interval
        u32 source_path_bytes.size.to_u32
        u64 checkpoint_metas.size.to_u64
        u64 names.size.to_u64
        u64 windows_offset
        u64 record_count
      end
      io.write(source_path_bytes)
      checkpoint_metas.each do |checkpoint|
        Fqix::BinaryIO.write(io) do
          u64 checkpoint.out_offset
          u64 checkpoint.in_offset
          u8 checkpoint.bits
          u32 checkpoint.have
        end
      end
      names.each do |entry|
        name_bytes = entry.name.to_slice
        Fqix::BinaryIO.write(io) do
          u16 name_bytes.size.to_u16
          bytes name_bytes
          u64 entry.uncompressed_offset
          u64 entry.checkpoint_id
          u64 entry.delta
        end
      end
      windows.each { |window| io.write(window) }
    end
  end
end

describe Fqix::Fastq do
  it "parses a FASTQ read name" do
    Fqix::Fastq.name_from_header("@read1 some comment\n").should eq("read1")
  end

  it "parses a FASTQ read name before tab-separated comments" do
    Fqix::Fastq.name_from_header("@read2\tmore comment\n").should eq("read2")
  end

  it "allows empty read names because fqix is not a FASTQ validator" do
    Fqix::Fastq.name_from_header("@ comment\n").should eq("")
  end

  it "frames four-line FASTQ with final newline omitted or CRLF line endings" do
    SpecIndexSupport.parse_fastq_text("@read1\nACGT\n+\nIIII").should eq(["@read1\nACGT\n+\nIIII"])
    SpecIndexSupport.parse_fastq_text("@read2\r\nACGT\r\n+\r\nIIII\r\n").should eq(["@read2\r\nACGT\r\n+\r\nIIII\r\n"])
  end

  it "preserves unusual four-line records instead of validating FASTQ semantics" do
    records = [
      "@plus\nACGT\n-\nIIII\n",
      "@short\nACGT\n+\nIII\n",
      "@long\nACGT\n+\nIIIII\n",
    ]

    SpecIndexSupport.parse_fastq_text(records.join).should eq(records)
  end

  it "still rejects incomplete four-line framing in strict mode" do
    expect_raises(Fqix::Error, "truncated FASTQ record at end of stream") do
      SpecIndexSupport.parse_fastq_text("@wrapped\nAC\nGT\n+\nIIII\n")
    end
  end
end

describe Fqix::Order do
  it "compares read names with natural numeric runs" do
    Fqix::Order.compare("DRR000001.904", "DRR000001.1077", Fqix::OrderMode::Natural).should be < 0
    Fqix::Order.compare("read.9", "read.10", Fqix::OrderMode::Natural).should be < 0
    Fqix::Order.compare("read.01", "read.1", Fqix::OrderMode::Natural).should be > 0
    Fqix::Order.compare("read", "read1", Fqix::OrderMode::Natural).should be < 0
    Fqix::Order.compare("read0", "read00", Fqix::OrderMode::Natural).should be < 0
  end
end

describe Fqix::Index do
  context "format compatibility and validation" do
    it "reads sparse v1.0 indexes as lexicographic order" do
      index_path = File.tempname("fqix-sparse-v1-0-spec", ".fqix")

      begin
        SpecIndexSupport.write_sparse_v1_index(
          index_path,
          "reads.fastq.gz",
          [] of Fqix::CheckpointMeta,
          [] of Fqix::NameEntry,
          [] of Bytes,
          record_count: 3_u64
        )

        index = Fqix::Index.read(index_path)
        index.format_version.should eq(Fqix::FormatVersion.new(1_u16, 0_u16))
        index.order_mode.should eq(Fqix::OrderMode::Lexicographic)
        index.record_count.should eq(3_u64)
      ensure
        File.delete(index_path) if File.exists?(index_path)
      end
    end

    it "rejects unsupported future indexes" do
      index_path = File.tempname("fqix-v3-reject-spec", ".fqix")

      begin
        SpecIndexSupport.write_index_with_version(index_path, 3_u16)

        expect_raises(Fqix::Error, "unsupported fqix format 3.0; please rebuild the index") do
          Fqix::Index.read(index_path)
        end
      ensure
        File.delete(index_path) if File.exists?(index_path)
      end
    end

    it "rejects a corrupt index with an impossible checkpoint count" do
      index_path = File.tempname("fqix-bad-checkpoint-count-spec", ".fqix")

      begin
        SpecIndexSupport.write_index_header(index_path, ncheckpoints: UInt64::MAX)

        expect_raises(Fqix::Error, "invalid fqix index checkpoint count") do
          Fqix::Index.read(index_path)
        end
      ensure
        File.delete(index_path) if File.exists?(index_path)
      end
    end

    it "rejects checkpoint metadata with invalid bit count" do
      index_path = File.tempname("fqix-bad-checkpoint-bits-spec", ".fqix")

      begin
        SpecIndexSupport.write_exact_index_with_checkpoint_meta(index_path, bits: 8_u8)

        expect_raises(Fqix::Error, "invalid fqix checkpoint bits") do
          Fqix::Index.read(index_path)
        end
      ensure
        File.delete(index_path) if File.exists?(index_path)
      end
    end

    it "rejects checkpoint metadata with an oversized dictionary" do
      index_path = File.tempname("fqix-bad-checkpoint-have-spec", ".fqix")

      begin
        SpecIndexSupport.write_exact_index_with_checkpoint_meta(index_path, have: (Fqix::Zran::WINDOW_SIZE + 1).to_u32)

        expect_raises(Fqix::Error, "invalid fqix checkpoint dictionary size") do
          Fqix::Index.read(index_path)
        end
      ensure
        File.delete(index_path) if File.exists?(index_path)
      end
    end

    it "rejects an index whose checkpoint windows are truncated" do
      index_path = File.tempname("fqix-short-windows-spec", ".fqix")

      begin
        SpecIndexSupport.write_exact_index_with_checkpoint_meta(index_path, window_bytes: Fqix::Zran::WINDOW_SIZE - 1)

        expect_raises(Fqix::Error, "invalid fqix index window section") do
          Fqix::Index.read(index_path)
        end
      ensure
        File.delete(index_path) if File.exists?(index_path)
      end
    end

    it "rejects a sparse name entry with an out-of-range checkpoint id" do
      index_path = File.tempname("fqix-bad-sparse-checkpoint-id-spec", ".fqix")
      checkpoints = [Fqix::CheckpointMeta.new(100_u64, 0_u64, 0_u8, 0_u32)]
      names = [Fqix::NameEntry.new("read1", 100_u64, 1_u64, 0_u64)]

      begin
        SpecIndexSupport.write_sparse_v1_index(index_path, "reads.fastq.gz", checkpoints, names, [Bytes.new(Fqix::Zran::WINDOW_SIZE)])

        expect_raises(Fqix::Error, "invalid fqix sparse name checkpoint reference") do
          Fqix::Index.read(index_path)
        end
      ensure
        File.delete(index_path) if File.exists?(index_path)
      end
    end

    it "rejects a sparse name entry whose offset precedes its checkpoint" do
      index_path = File.tempname("fqix-bad-sparse-offset-spec", ".fqix")
      checkpoints = [Fqix::CheckpointMeta.new(100_u64, 0_u64, 0_u8, 0_u32)]
      names = [Fqix::NameEntry.new("read1", 99_u64, 0_u64, 0_u64)]

      begin
        SpecIndexSupport.write_sparse_v1_index(index_path, "reads.fastq.gz", checkpoints, names, [Bytes.new(Fqix::Zran::WINDOW_SIZE)])

        expect_raises(Fqix::Error, "invalid fqix sparse name checkpoint reference") do
          Fqix::Index.read(index_path)
        end
      ensure
        File.delete(index_path) if File.exists?(index_path)
      end
    end

    it "rejects a sparse name entry whose delta disagrees with its checkpoint" do
      index_path = File.tempname("fqix-bad-sparse-delta-spec", ".fqix")
      checkpoints = [Fqix::CheckpointMeta.new(100_u64, 0_u64, 0_u8, 0_u32)]
      names = [Fqix::NameEntry.new("read1", 120_u64, 0_u64, 19_u64)]

      begin
        SpecIndexSupport.write_sparse_v1_index(index_path, "reads.fastq.gz", checkpoints, names, [Bytes.new(Fqix::Zran::WINDOW_SIZE)])

        expect_raises(Fqix::Error, "invalid fqix sparse name checkpoint reference") do
          Fqix::Index.read(index_path)
        end
      ensure
        File.delete(index_path) if File.exists?(index_path)
      end
    end

    it "rejects exact entries with reserved flags" do
      index_path = File.tempname("fqix-bad-entry-flags-spec", ".fqix")

      begin
        SpecIndexSupport.write_exact_index_with_entry_flags(index_path, 1_u32)

        expect_raises(Fqix::Error, "unsupported fqix entry flags") do
          Fqix::Index.read(index_path)
        end
      ensure
        File.delete(index_path) if File.exists?(index_path)
      end
    end

    it "rejects exact entries whose name table reference is out of range" do
      index_path = File.tempname("fqix-bad-entry-name-ref-spec", ".fqix")
      entry = Fqix::Entry.new(0_u64, 3_u64, 2_u32, 0_u64, 0_u64, 0_u64)

      begin
        SpecIndexSupport.write_exact_index_with_entries(index_path, [entry], Bytes[1_u8, 2_u8, 3_u8, 4_u8])

        expect_raises(Fqix::Error, "invalid fqix index name table reference") do
          Fqix::Index.read(index_path)
        end
      ensure
        File.delete(index_path) if File.exists?(index_path)
      end
    end

    it "rejects exact entry tables that are not sorted" do
      index_path = File.tempname("fqix-unsorted-entry-table-spec", ".fqix")
      entries = [
        Fqix::Entry.new(2_u64, 0_u64, 0_u32, 0_u64, 0_u64, 0_u64),
        Fqix::Entry.new(1_u64, 0_u64, 0_u32, 1_u64, 0_u64, 0_u64),
      ]

      begin
        SpecIndexSupport.write_exact_index_with_entries(index_path, entries)

        expect_raises(Fqix::Error, "invalid fqix index entry order") do
          Fqix::Index.read(index_path)
        end
      ensure
        File.delete(index_path) if File.exists?(index_path)
      end
    end

    it "rejects a corrupt index with an impossible entry count" do
      index_path = File.tempname("fqix-bad-name-count-spec", ".fqix")

      begin
        SpecIndexSupport.write_index_header(index_path, nnames: UInt64::MAX)

        expect_raises(Fqix::Error, "invalid fqix index entry count") do
          Fqix::Index.read(index_path)
        end
      ensure
        File.delete(index_path) if File.exists?(index_path)
      end
    end

    it "rejects a v1 sparse index whose name entry overruns the window section" do
      index_path = File.tempname("fqix-bad-v1-name-table-spec", ".fqix")

      begin
        File.open(index_path, "wb") do |io|
          io.write(Fqix::IndexFormat::MAGIC_V1.to_slice)
          Fqix::IndexFormat.write_version(io, Fqix::IndexFormat::SPARSE_VERSION)
          Fqix::BinaryIO.write_u16(io, 0_u16)
          Fqix::BinaryIO.write_u16(io, 0_u16)
          Fqix::BinaryIO.write_u64(io, 0_u64)
          Fqix::BinaryIO.write_i64(io, 0_i64)
          Fqix::BinaryIO.write_u64(io, 1_u64)
          Fqix::BinaryIO.write_u32(io, 1_u32)
          Fqix::BinaryIO.write_u32(io, 0_u32)
          Fqix::BinaryIO.write_u64(io, 0_u64)
          Fqix::BinaryIO.write_u64(io, 1_u64)
          Fqix::BinaryIO.write_u64(io, Fqix::IndexFormat::V1_HEADER_SIZE + Fqix::IndexFormat::MIN_NAME_ENTRY_SIZE)
          Fqix::BinaryIO.write_u64(io, 1_u64)
          Fqix::BinaryIO.write_u8(io, Fqix::OrderMode::Lexicographic.value)
          io.write(Bytes.new(7))
          Fqix::BinaryIO.write_u16(io, 10_u16)
          io.write(Bytes.new((Fqix::IndexFormat::MIN_NAME_ENTRY_SIZE - 2_u64).to_i))
        end

        expect_raises(Fqix::Error, "invalid fqix index name table") do
          Fqix::Index.read(index_path)
        end
      ensure
        File.delete(index_path) if File.exists?(index_path)
      end
    end

    it "rejects sparse v1.1 indexes with unsupported order metadata" do
      index_path = File.tempname("fqix-bad-order-mode-spec", ".fqix")

      begin
        File.open(index_path, "wb") do |io|
          io.write(Fqix::IndexFormat::MAGIC_V1.to_slice)
          Fqix::IndexFormat.write_version(io, Fqix::IndexFormat::SPARSE_VERSION)
          Fqix::BinaryIO.write_u16(io, 0_u16)
          Fqix::BinaryIO.write_u16(io, 0_u16)
          Fqix::BinaryIO.write_u64(io, 0_u64)
          Fqix::BinaryIO.write_i64(io, 0_i64)
          Fqix::BinaryIO.write_u64(io, 1_u64)
          Fqix::BinaryIO.write_u32(io, 1_u32)
          Fqix::BinaryIO.write_u32(io, 0_u32)
          Fqix::BinaryIO.write_u64(io, 0_u64)
          Fqix::BinaryIO.write_u64(io, 0_u64)
          Fqix::BinaryIO.write_u64(io, Fqix::IndexFormat::V1_HEADER_SIZE)
          Fqix::BinaryIO.write_u64(io, 0_u64)
          Fqix::BinaryIO.write_u8(io, 255_u8)
          io.write(Bytes.new(7))
        end

        expect_raises(Fqix::Error, "unsupported fqix order mode 255") do
          Fqix::Index.read(index_path)
        end
      ensure
        File.delete(index_path) if File.exists?(index_path)
      end

      begin
        File.open(index_path, "wb") do |io|
          io.write(Fqix::IndexFormat::MAGIC_V1.to_slice)
          Fqix::IndexFormat.write_version(io, Fqix::IndexFormat::SPARSE_VERSION)
          Fqix::BinaryIO.write_u16(io, 0_u16)
          Fqix::BinaryIO.write_u16(io, 0_u16)
          Fqix::BinaryIO.write_u64(io, 0_u64)
          Fqix::BinaryIO.write_i64(io, 0_i64)
          Fqix::BinaryIO.write_u64(io, 1_u64)
          Fqix::BinaryIO.write_u32(io, 1_u32)
          Fqix::BinaryIO.write_u32(io, 0_u32)
          Fqix::BinaryIO.write_u64(io, 0_u64)
          Fqix::BinaryIO.write_u64(io, 0_u64)
          Fqix::BinaryIO.write_u64(io, Fqix::IndexFormat::V1_HEADER_SIZE)
          Fqix::BinaryIO.write_u64(io, 0_u64)
          Fqix::BinaryIO.write_u8(io, Fqix::OrderMode::Lexicographic.value)
          io.write(Bytes[1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8])
        end

        expect_raises(Fqix::Error, "unsupported fqix sparse order header flags") do
          Fqix::Index.read(index_path)
        end
      ensure
        File.delete(index_path) if File.exists?(index_path)
      end
    end
  end

  context "sparse indexes" do
    it "builds a sparse v1 index for sorted FASTQ" do
      gz_path = File.tempname("fqix-sparse-spec", ".fastq.gz")
      index_path = "#{gz_path}.fqix"
      records = (0...12).map do |i|
        name = "read%02d" % i
        {name, "@#{name}\nACGT\n+\nIIII\n"}
      end

      begin
        SpecIndexSupport.write_gzip_member(gz_path, records)
        index = Fqix::Index.build(gz_path, checkpoint_span: 64_u64, mode: Fqix::IndexMode::Sparse, name_interval: 3_u32)
        index.mode.sparse?.should be_true
        index.format_version.should eq(Fqix::IndexFormat::SPARSE_VERSION)
        index.order_mode.should eq(Fqix::OrderMode::Lexicographic)
        index.names.size.should be > 1
        index.entries.empty?.should be_true
        index.write(index_path)

        read_index = Fqix::Index.read(index_path)
        read_index.mode.sparse?.should be_true
        read_index.format_version.should eq(Fqix::IndexFormat::SPARSE_VERSION)
        read_index.order_mode.should eq(Fqix::OrderMode::Lexicographic)
        read_index.record_count.should eq(index.record_count)
        read_index.names.size.should eq(index.names.size)
        Fqix::Reader.new(gz_path, read_index).fetch("read08", 4096_u64).should eq(records[8][1])
      ensure
        File.delete(gz_path) if File.exists?(gz_path)
        File.delete(index_path) if File.exists?(index_path)
      end
    end

    it "builds and reads a sparse index with natural read-name order" do
      gz_path = File.tempname("fqix-sparse-natural-spec", ".fastq.gz")
      index_path = "#{gz_path}.fqix"
      records = [
        {"DRR000001.265", "@DRR000001.265 3060N:7:1:502:2032 length=36\nGTTTTTCCCCATTATTTATACCTCTGATAAAAGTAA\n+\nIIIIIIIIII<II@IGIHI3B3IA?1322+)--/:%\n"},
        {"DRR000001.572", "@DRR000001.572 3060N:7:1:620:2034 length=36\nGGTGACAGCAGGATTACGGAAGACANNNNTNNGNNT\n+\nIIIIIIIIIIIIHAC=869-3852*!!!!+!!#!!0\n"},
        {"DRR000001.904", "@DRR000001.904 3060N:7:1:873:2032 length=36\nGGCGGTTGTCAAAATAGGGATTCGATTTGCCGTTAA\n+\nIIIII*I>I6+9AI+F.:I138(.(,1<&&(%)*(&\n"},
        {"DRR000001.1077", "@DRR000001.1077 3060N:7:1:596:2031 length=36\nGTAGCGAAATTCCTTGTCGGGTAAGTTCCGACCCGC\n+\nIIIIIIIGIIIICDBI1II9<55:7949./++3.19\n"},
      ]

      begin
        SpecIndexSupport.write_gzip_member(gz_path, records)
        expect_raises(Fqix::Error, /--name-order lex/) do
          Fqix::Index.build(gz_path, checkpoint_span: 64_u64, mode: Fqix::IndexMode::Sparse, order_mode: Fqix::OrderMode::Lexicographic)
        end

        # Auto (the default) detects natural for this width-varying numeric data.
        auto_index = Fqix::Index.build(gz_path, checkpoint_span: 64_u64, mode: Fqix::IndexMode::Sparse)
        auto_index.order_mode.should eq(Fqix::OrderMode::Natural)

        index = Fqix::Index.build(gz_path, checkpoint_span: 64_u64, mode: Fqix::IndexMode::Sparse, order_mode: Fqix::OrderMode::Natural)
        index.order_mode.should eq(Fqix::OrderMode::Natural)
        index.format_version.should eq(Fqix::FormatVersion.new(1_u16, 1_u16))
        index.write(index_path)

        read_index = Fqix::Index.read(index_path)
        read_index.order_mode.should eq(Fqix::OrderMode::Natural)
        Fqix::Reader.new(gz_path, read_index).fetch("DRR000001.1077", 4096_u64).should eq(records[3][1])
      ensure
        File.delete(gz_path) if File.exists?(gz_path)
        File.delete(index_path) if File.exists?(index_path)
      end
    end

    it "rejects sparse mode for unsorted FASTQ and points users to exact mode" do
      gz_path = File.tempname("fqix-sparse-unsorted-spec", ".fastq.gz")
      records = [
        {"read_C", "@read_C\nCCCC\n+\nIIII\n"},
        {"read_A", "@read_A\nAAAA\n+\nIIII\n"},
      ]

      begin
        SpecIndexSupport.write_gzip_member(gz_path, records)
        expect_raises(Fqix::Error, /use --mode exact/) do
          Fqix::Index.build(gz_path, checkpoint_span: 64_u64, mode: Fqix::IndexMode::Sparse)
        end
      ensure
        File.delete(gz_path) if File.exists?(gz_path)
      end
    end

    it "does not expose partial sparse matches at scan-limit line boundaries" do
      gz_path = File.tempname("fqix-sparse-partial-limit-spec", ".fastq.gz")
      records = [
        {"read00", "@read00\nAAAA\n+\nIIII\n"},
      ]
      limits = [
        {"header", 4_u64},
        {"sequence", 10_u64},
        {"plus", 14_u64},
        {"quality", 17_u64},
      ]

      begin
        SpecIndexSupport.write_gzip_member(gz_path, records)
        index = Fqix::Index.build(gz_path, checkpoint_span: 64_u64, mode: Fqix::IndexMode::Sparse)
        reader = Fqix::Reader.new(gz_path, index)

        limits.each do |_, limit|
          result = reader.fetch_matches_with_status("read00", limit)
          result.status.should eq(Fqix::Reader::FetchStatus::ScanLimitReached)
          result.matches.should be_empty

          expect_raises(Fqix::Error, "scan limit reached before lookup completed: read00") do
            reader.fetch_matches("read00", limit)
          end
        end

        expect_raises(Fqix::Error, "scan limit reached before lookup completed: read00") do
          reader.fetch_all("read00", 17_u64)
        end
        expect_raises(Fqix::Error, "scan limit reached before lookup completed: read00") do
          reader.fetch("read00", 17_u64)
        end
      ensure
        File.delete(gz_path) if File.exists?(gz_path)
      end
    end
  end

  context "exact indexes" do
    it "fetches reads from an unsorted gzip FASTQ" do
      gz_path = File.tempname("fqix-unsorted-spec", ".fastq.gz")
      records = [
        {"read_C", "@read_C\nCCCC\n+\nIIII\n"},
        {"read_A", "@read_A\nAAAA\n+\nIIII\n"},
        {"read_B", "@read_B\nBBBB\n+\nIIII\n"},
      ]

      begin
        SpecIndexSupport.write_gzip_member(gz_path, records)

        index = Fqix::Index.build(gz_path, checkpoint_span: 64_u64, mode: Fqix::IndexMode::Exact)
        index.input_names_sorted?.should be_false
        reader = Fqix::Reader.new(gz_path, index)

        records.each do |name, record|
          reader.fetch(name).should eq(record)
        end
      ensure
        File.delete(gz_path) if File.exists?(gz_path)
      end
    end

    it "normalizes query names with the index name mode" do
      gz_path = File.tempname("fqix-query-normalize-spec", ".fastq.gz")
      records = [
        {"read1", "@read1 comment\nACGT\n+\nIIII\n"},
      ]

      begin
        SpecIndexSupport.write_gzip_member(gz_path, records)

        index = Fqix::Index.build(gz_path, checkpoint_span: 64_u64, mode: Fqix::IndexMode::Exact)
        index.find_entries("read1 extra").size.should eq(1)
        index.find_entries("@read1 extra").size.should eq(0)

        reader = Fqix::Reader.new(gz_path, index)
        reader.fetch("read1 extra").should eq(records[0][1])
        reader.fetch("@read1 extra").should be_nil
      ensure
        File.delete(gz_path) if File.exists?(gz_path)
      end
    end

    it "fetches a read whose normalized name starts with at-sign" do
      gz_path = File.tempname("fqix-at-name-spec", ".fastq.gz")
      records = [
        {"@weird", "@@weird comment\nACGT\n+\nIIII\n"},
      ]

      begin
        SpecIndexSupport.write_gzip_member(gz_path, records)

        index = Fqix::Index.build(gz_path, checkpoint_span: 64_u64, mode: Fqix::IndexMode::Exact)
        index.find_entries("@weird").size.should eq(1)
        index.find_entries("@@weird").size.should eq(0)

        reader = Fqix::Reader.new(gz_path, index)
        reader.fetch("@weird").should eq(records[0][1])
        reader.fetch("@@weird").should be_nil
      ensure
        File.delete(gz_path) if File.exists?(gz_path)
      end
    end

    it "indexes and fetches unusual four-line records without validating FASTQ semantics" do
      gz_path = File.tempname("fqix-unusual-four-line-spec", ".fastq.gz")
      records = [
        {"plus", "@plus\nACGT\n-\nIIII\n"},
        {"short", "@short\nACGT\n+\nIII\n"},
        {"long", "@long\nACGT\n+\nIIIII\n"},
      ]

      begin
        SpecIndexSupport.write_gzip_member(gz_path, records)
        index = Fqix::Index.build(gz_path, checkpoint_span: 64_u64, mode: Fqix::IndexMode::Exact)
        reader = Fqix::Reader.new(gz_path, index)

        records.each do |name, record|
          reader.fetch(name).should eq(record)
        end
      ensure
        File.delete(gz_path) if File.exists?(gz_path)
      end
    end

    it "uses exact name comparison within hash-colliding entry ranges" do
      entries, name_table = Fqix::Index.build_entries(
        [
          Fqix::RawEntry.new("alpha", 0_u64, 0_u64, 20_u64),
          Fqix::RawEntry.new("beta", 1_u64, 20_u64, 20_u64),
        ],
        Fqix::HashAlgorithm::TestZero,
        0_u64
      )
      index = Fqix::Index.new(
        "reads.fastq.gz",
        0_u64,
        0_i64,
        1_u64,
        Fqix::HashAlgorithm::TestZero,
        0_u64,
        Fqix::NameMode::FirstToken,
        2_u64,
        true,
        [] of Fqix::CheckpointMeta,
        entries,
        name_table,
        Fqix::MemoryWindowStore.new([] of Bytes)
      )

      matches = index.find_entries("beta extra")
      matches.size.should eq(1)
      index.entry_name(matches.first).should eq("beta")
    end

    it "rejects fetching from an index with entries but no checkpoints" do
      entries, name_table = Fqix::Index.build_entries(
        [
          Fqix::RawEntry.new("read1", 0_u64, 0_u64, 20_u64),
        ],
        Fqix::HashAlgorithm::Fnv1a64,
        0_u64
      )
      index = Fqix::Index.new(
        "reads.fastq.gz",
        0_u64,
        0_i64,
        1_u64,
        Fqix::HashAlgorithm::Fnv1a64,
        0_u64,
        Fqix::NameMode::FirstToken,
        1_u64,
        true,
        [] of Fqix::CheckpointMeta,
        entries,
        name_table,
        Fqix::MemoryWindowStore.new([] of Bytes)
      )

      expect_raises(Fqix::Error, "invalid fqix index checkpoint count") do
        Fqix::Reader.new("reads.fastq.gz", index).fetch("read1")
      end
    end

    it "detects an index/source mismatch after seeking to a record" do
      gz_path = File.tempname("fqix-mismatch-spec", ".fastq.gz")
      original = [
        {"read1", "@read1\nACGT\n+\nIIII\n"},
      ]
      replacement = [
        {"readX", "@readX\nACGT\n+\nIIII\n"},
      ]

      begin
        SpecIndexSupport.write_gzip_member(gz_path, original)
        index = Fqix::Index.build(gz_path, checkpoint_span: 64_u64, mode: Fqix::IndexMode::Exact)
        SpecIndexSupport.write_gzip_member(gz_path, replacement)

        expect_raises(Fqix::Error, "index/input mismatch for read1: found readX at indexed offset") do
          Fqix::Reader.new(gz_path, index).fetch("read1")
        end
      ensure
        File.delete(gz_path) if File.exists?(gz_path)
      end
    end
  end

  context "gzip and checkpoint integration" do
    it "builds checkpoints and fetches reads from a gzip FASTQ" do
      gz_path = File.tempname("fqix-spec", ".fastq.gz")
      index_path = "#{gz_path}.fqix"
      records = (0...500).map do |i|
        name = "read%04d" % i
        sequence = "ACGT" * 80
        quality = "I" * sequence.bytesize
        {name, "@#{name} comment\n#{sequence}\n+\n#{quality}\n"}
      end

      begin
        File.open(gz_path, "wb") do |file|
          Compress::Gzip::Writer.open(file) do |gzip|
            records.each_with_index do |(_, record), i|
              gzip << record
              gzip.flush if i % 25 == 0
            end
          end
        end

        index = Fqix::Index.build(gz_path, checkpoint_span: 1024_u64, mode: Fqix::IndexMode::Exact)
        index.checkpoint_metas.size.should be > 1
        index.write(index_path)

        reader = Fqix::Reader.new(gz_path, index)
        [0, 123, 499].each do |record_index|
          name, record = records[record_index]
          reader.fetch(name).should eq(record)
        end

        read_index = Fqix::Index.read(index_path)
        read_index.format_version.should eq(Fqix::IndexFormat::EXACT_VERSION)
        read_index.source_path.should eq(gz_path)
        read_index.checkpoint_metas.size.should eq(index.checkpoint_metas.size)
        Fqix::Reader.new(gz_path, read_index).fetch("read0400").should eq(records[400][1])

        batch = Fqix::Reader.new(gz_path, read_index).fetch_many(["read0123", "missing", "read0000", "read0123"])
        batch.map(&.status).should eq([
          Fqix::Reader::FetchStatus::Found,
          Fqix::Reader::FetchStatus::NotFound,
          Fqix::Reader::FetchStatus::Found,
          Fqix::Reader::FetchStatus::Found,
        ])
        batch[0].record.should eq(records[123][1])
        batch[2].record.should eq(records[0][1])
        batch[3].record.should eq(records[123][1])
      ensure
        File.delete(gz_path) if File.exists?(gz_path)
        File.delete(index_path) if File.exists?(index_path)
      end
    end

    it "fetches reads from concatenated gzip members" do
      gz_path = File.tempname("fqix-multimember-spec", ".fastq.gz")
      records = (0...10).map do |i|
        name = "read%02d" % i
        sequence = "ACGT" * 6
        quality = "I" * sequence.bytesize
        {name, "@#{name}\n#{sequence}\n+\n#{quality}\n"}
      end

      begin
        SpecIndexSupport.write_gzip_member(gz_path, records[0, 5])
        SpecIndexSupport.write_gzip_member(gz_path, records[5, 5], append: true)

        index = Fqix::Index.build(gz_path, checkpoint_span: 64_u64, mode: Fqix::IndexMode::Exact)
        index.entries.map { |entry| index.entry_name(entry) }.should contain("read08")

        reader = Fqix::Reader.new(gz_path, index)
        reader.fetch("read08").should eq(records[8][1])
        reader.fetch_with_status("read08").status.found?.should be_true
        reader.fetch_many(["read08"]).first.status.found?.should be_true
      ensure
        File.delete(gz_path) if File.exists?(gz_path)
      end
    end

    it "fetches reads after crossing multiple gzip member boundaries" do
      gz_path = File.tempname("fqix-many-members-spec", ".fastq.gz")
      records = (0...15).map do |i|
        name = "read%02d" % i
        sequence = "ACGT" * 8
        quality = "I" * sequence.bytesize
        {name, "@#{name}\n#{sequence}\n+\n#{quality}\n"}
      end

      begin
        SpecIndexSupport.write_gzip_member(gz_path, records[0, 5])
        SpecIndexSupport.write_gzip_member(gz_path, records[5, 5], append: true)
        SpecIndexSupport.write_gzip_member(gz_path, records[10, 5], append: true)

        index = Fqix::Index.build(gz_path, checkpoint_span: 4096_u64, mode: Fqix::IndexMode::Exact)
        index.entries.map { |entry| index.entry_name(entry) }.should contain("read12")
        index.checkpoint_metas.size.should eq(1)

        reader = Fqix::Reader.new(gz_path, index)
        reader.fetch("read12").should eq(records[12][1])
      ensure
        File.delete(gz_path) if File.exists?(gz_path)
      end
    end

    it "fetches reads when a gzip member boundary splits a FASTQ record" do
      gz_path = File.tempname("fqix-split-record-spec", ".fastq.gz")
      records = (0...12).map do |i|
        name = "read%02d" % i
        sequence = "ACGTN" * 20
        quality = "I" * sequence.bytesize
        {name, "@#{name}\n#{sequence}\n+\n#{quality}\n"}
      end
      plain = records.map(&.[1]).join
      split = plain.index!("read08") + 17

      begin
        SpecIndexSupport.write_gzip_text_member(gz_path, plain.byte_slice(0, split))
        SpecIndexSupport.write_gzip_text_member(gz_path, plain.byte_slice(split, plain.bytesize - split), append: true)

        index = Fqix::Index.build(gz_path, checkpoint_span: 64_u64, mode: Fqix::IndexMode::Exact)
        reader = Fqix::Reader.new(gz_path, index)
        reader.fetch("read08").should eq(records[8][1])
      ensure
        File.delete(gz_path) if File.exists?(gz_path)
      end
    end

    it "loads checkpoint windows lazily from a v2 index" do
      gz_path = File.tempname("fqix-lazy-window-spec", ".fastq.gz")
      index_path = "#{gz_path}.fqix"
      records = (0...400).map do |i|
        name = "read%04d" % i
        sequence = "ACGTN" * 24
        quality = "I" * sequence.bytesize
        {name, "@#{name}\n#{sequence}\n+\n#{quality}\n"}
      end

      begin
        File.open(gz_path, "wb") do |file|
          Compress::Gzip::Writer.open(file) do |gzip|
            records.each_with_index do |(_, record), index|
              gzip << record
              gzip.flush if index % 10 == 0
            end
          end
        end

        built = Fqix::Index.build(gz_path, checkpoint_span: 512_u64, mode: Fqix::IndexMode::Exact)
        built.checkpoint_metas.size.should be > 1
        built.write(index_path)

        read_index = Fqix::Index.read(index_path)
        read_index.format_version.should eq(Fqix::IndexFormat::EXACT_VERSION)
        read_index.checkpoint_metas.should eq(built.checkpoint_metas)

        built.checkpoint_metas.each_index do |index|
          read_index.checkpoint(index).window.should eq(built.checkpoint(index).window)
        end
      ensure
        File.delete(gz_path) if File.exists?(gz_path)
        File.delete(index_path) if File.exists?(index_path)
      end
    end
  end
end
