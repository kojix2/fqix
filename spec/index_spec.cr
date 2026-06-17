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

  def write_index_with_version(path : String, version : UInt32)
    File.open(path, "wb") do |io|
      io.write(Fqix::Index::MAGIC.to_slice)
      Fqix::BinaryIO.write_u32(io, version)
    end
  end
end

describe Fqix::Fastq do
  it "parses a FASTQ read name" do
    Fqix::Fastq.parse_read_name("@read1 some comment\n").should eq("read1")
  end

  it "parses a FASTQ read name before tab-separated comments" do
    Fqix::Fastq.parse_read_name("@read2\tmore comment\n").should eq("read2")
  end

  it "reads raw lines with newlines preserved" do
    io = IO::Memory.new("abc\ndef")

    Fqix::Fastq.gets_raw(io).should eq("abc\n")
    Fqix::Fastq.gets_raw(io).should eq("def")
    Fqix::Fastq.gets_raw(io).should be_nil
  end
end

describe Fqix::Index do
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

      index = Fqix::Index.build(gz_path, checkpoint_span: 1024_u64, name_interval: 7_u32)
      index.checkpoint_metas.size.should be > 1
      index.write(index_path)

      reader = Fqix::Reader.new(gz_path, index)
      [0, 123, 499].each do |record_index|
        name, record = records[record_index]
        reader.fetch(name, 64_u64 * 1024_u64).should eq(record)
      end

      read_index = Fqix::Index.read(index_path)
      read_index.format_version.should eq(3)
      read_index.source_path.should eq(gz_path)
      read_index.checkpoint_metas.size.should eq(index.checkpoint_metas.size)
      Fqix::Reader.new(gz_path, read_index).fetch("read0400", 64_u64 * 1024_u64).should eq(records[400][1])
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

      index = Fqix::Index.build(gz_path, checkpoint_span: 64_u64, name_interval: 1_u32)
      index.names.map(&.name).should contain("read08")

      reader = Fqix::Reader.new(gz_path, index)
      reader.fetch("read08", 4096_u64).should eq(records[8][1])
      reader.fetch_with_status("read08", 8_u64).status.scan_limit_reached?.should be_true
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

      index = Fqix::Index.build(gz_path, checkpoint_span: 4096_u64, name_interval: 1_u32)
      index.names.map(&.name).should contain("read12")
      index.checkpoint_metas.size.should eq(1)

      reader = Fqix::Reader.new(gz_path, index)
      reader.fetch("read12", 4096_u64).should eq(records[12][1])
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

      index = Fqix::Index.build(gz_path, checkpoint_span: 64_u64, name_interval: 1_u32)
      reader = Fqix::Reader.new(gz_path, index)
      reader.fetch("read08", 4096_u64).should eq(records[8][1])
    ensure
      File.delete(gz_path) if File.exists?(gz_path)
    end
  end

  it "loads checkpoint windows lazily from a v3 index" do
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

      built = Fqix::Index.build(gz_path, checkpoint_span: 512_u64, name_interval: 9_u32)
      built.checkpoint_metas.size.should be > 1
      built.write(index_path)

      read_index = Fqix::Index.read(index_path)
      read_index.format_version.should eq(3)
      read_index.checkpoint_metas.should eq(built.checkpoint_metas)

      built.checkpoint_metas.each_index do |index|
        read_index.checkpoint(index).window.should eq(built.checkpoint(index).window)
      end
    ensure
      File.delete(gz_path) if File.exists?(gz_path)
      File.delete(index_path) if File.exists?(index_path)
    end
  end

  it "rejects pre-v3 indexes" do
    index_path = File.tempname("fqix-v2-reject-spec", ".fqix")

    begin
      SpecIndexSupport.write_index_with_version(index_path, 2_u32)

      expect_raises(Fqix::Error, "unsupported fqix version 2; please rebuild the index") do
        Fqix::Index.read(index_path)
      end
    ensure
      File.delete(index_path) if File.exists?(index_path)
    end
  end
end
