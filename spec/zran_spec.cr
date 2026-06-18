require "./spec_helper"

lib LibC
  fun fopen(filename : UInt8*, mode : UInt8*) : Void*
  fun fclose(stream : Void*) : Int
end

lib LibZranReference
  fun deflate_index_build(input : Void*, span : LibC::Long, built : Void**) : LibC::Int
  fun deflate_index_extract(input : Void*, index : Void*, offset : LibC::Long, buffer : UInt8*, length : LibC::SizeT) : LibC::Long
  fun deflate_index_free(index : Void*)
end

module SpecZranSupport
  extend self

  def with_reference_gzip(&)
    gz_path = File.tempname("fqix-zran-spec", ".fastq.gz")
    plain = build_reference_fastq

    begin
      File.open(gz_path, "wb") do |file|
        Compress::Gzip::Writer.open(file) do |gzip|
          plain.each_line(chomp: false).with_index do |line, index|
            gzip << line
            gzip.flush if index % 37 == 0
          end
        end
      end

      yield gz_path, plain
    ensure
      File.delete(gz_path) if File.exists?(gz_path)
    end
  end

  def with_reference_multimember_gzip(member_count : Int32 = 2, &)
    gz_path = File.tempname("fqix-zran-mm-spec", ".fastq.gz")
    plain = build_reference_fastq
    members = split_plain_members(plain, member_count)

    begin
      members.each_with_index do |member, index|
        write_gzip_member(gz_path, member, append: index > 0)
      end
      split = members.first.bytesize
      yield gz_path, plain, split
    ensure
      File.delete(gz_path) if File.exists?(gz_path)
    end
  end

  def crystal_extract(gz_path : String, checkpoints : Array(Fqix::Zran::Checkpoint), offset : Int32, length : Int32) : String
    checkpoint = checkpoints.reverse_each.find { |candidate| candidate.out_offset <= offset }
    raise "no checkpoint for offset #{offset}" unless checkpoint
    skip = offset.to_u64 - checkpoint.out_offset
    read_extract(gz_path, checkpoint, skip, length.to_u64)
  end

  def read_extract(gz_path : String, checkpoint : Fqix::Zran::Checkpoint, skip : UInt64, length : UInt64) : String
    tmp = Fqix::Zran.extract_to_temp(gz_path, checkpoint, skip, length)
    File.read(tmp)
  ensure
    File.delete(tmp) if tmp && File.exists?(tmp)
  end

  def reference_extract(gz_path : String, span : UInt64, offset : Int32, length : Int32) : String
    input = LibC.fopen(gz_path, "rb")
    raise "failed to open gzip for zran reference" if input.null?

    index = Pointer(Pointer(Void)).malloc(1)
    index.value = Pointer(Void).null

    begin
      points = LibZranReference.deflate_index_build(input, span.to_i64, index)
      raise "deflate_index_build failed: #{points}" if points < 0

      buffer = Bytes.new(length)
      got = LibZranReference.deflate_index_extract(input, index.value, offset.to_i64, buffer.to_unsafe, length)
      raise "deflate_index_extract failed: #{got}" if got < 0

      String.new(buffer[0, got.to_i])
    ensure
      LibZranReference.deflate_index_free(index.value) unless index.value.null?
      LibC.fclose(input)
    end
  end

  private def build_reference_fastq : String
    String.build do |io|
      900.times do |i|
        name = "read%04d" % i
        sequence = String.build do |seq|
          180.times do |j|
            seq << "ACGTN"[(i * 17 + j * 31) % 5]
          end
        end
        quality = String.build do |qual|
          sequence.bytesize.times do |j|
            qual << (33 + ((i + j) % 40)).chr
          end
        end
        io << '@' << name << " comment " << i << '\n'
        io << sequence << '\n'
        io << "+\n"
        io << quality << '\n'
      end
    end
  end

  private def write_gzip_member(path : String, text : String, append : Bool = false)
    File.open(path, append ? "ab" : "wb") do |file|
      Compress::Gzip::Writer.open(file) do |gzip|
        gzip << text
      end
    end
  end

  private def split_plain_members(plain : String, member_count : Int32) : Array(String)
    raise "member_count must be positive" if member_count <= 0

    members = Array(String).new(member_count)
    start = 0
    remaining = member_count
    while remaining > 1
      split = start + (plain.bytesize - start) // remaining
      until split >= plain.bytesize || plain.byte_at(split - 1) == '\n'.ord
        split += 1
      end
      members << plain.byte_slice(start, split - start)
      start = split
      remaining -= 1
    end
    members << plain.byte_slice(start, plain.bytesize - start)
    members
  end

  def sample_offsets(size : Int32) : Array(Int32)
    fixed = [0, 1, 17, 1023, 1024, 4095, 4096, 16_000, 32_767, 32_768, 65_535, 65_536, size - 4096, size - 1]
    generated = (0...60).map { |i| ((i.to_u64 * 1_103_515_245_u64 + 12_345_u64) % size).to_i }
    offsets = (fixed + generated).select { |offset| offset >= 0 && offset < size }
    offsets.uniq!
    offsets.sort!
    offsets
  end
end

describe Fqix::Zran do
  it "preserves Fqix::Error raised by a build consumer" do
    gz_path = File.tempname("fqix-zran-consumer-error-spec", ".fastq.gz")
    original = Fqix::Error.new("consumer failed")

    begin
      File.open(gz_path, "wb") do |file|
        Compress::Gzip::Writer.open(file) do |gzip|
          gzip << "@read1\nACGT\n+\nIIII\n"
        end
      end

      raised = expect_raises(Fqix::Error, "consumer failed") do
        Fqix::Zran.build_to_temp(gz_path, 1024_u64, ->(_chunk : Bytes) { raise original })
      end
      raised.should be(original)
      raised.cause.should be_nil
    ensure
      File.delete(gz_path) if File.exists?(gz_path)
    end
  end

  it "keeps the original cause when wrapping non-Fqix build errors" do
    raised = expect_raises(Fqix::Error) do
      Fqix::Zran.build_to_temp("/definitely/missing/fqix.fastq.gz", 1024_u64)
    end

    raised.cause.should be_a(File::Error)
  end

  it "rejects a corrupt temporary index with an impossible checkpoint count" do
    tmp = File.tempname("fqix-zran-bad-count-spec", ".tmp")

    begin
      File.open(tmp, "wb") do |io|
        io.write(Fqix::Zran::TMP_MAGIC.to_slice)
        Fqix::BinaryIO.write_u64(io, UInt64::MAX)
      end

      expect_raises(Fqix::Error, "invalid temporary zran checkpoint count") do
        Fqix::Zran.read_temp(tmp)
      end
    ensure
      File.delete(tmp) if File.exists?(tmp)
    end
  end

  it "matches Mark Adler's zran extraction across many offsets" do
    SpecZranSupport.with_reference_gzip do |gz_path, plain|
      span = 1024_u64
      tmp = Fqix::Zran.build_to_temp(gz_path, span)
      checkpoints = Fqix::Zran.read_temp(tmp)

      begin
        checkpoints.size.should be > 1
        offsets = SpecZranSupport.sample_offsets(plain.bytesize)
        lengths = [0, 1, 7, 128, 4096, 20_000, 70_000]

        offsets.each do |offset|
          lengths.each do |length|
            next if offset < 0 || offset >= plain.bytesize

            expected = SpecZranSupport.reference_extract(gz_path, span, offset, length)
            actual = SpecZranSupport.crystal_extract(gz_path, checkpoints, offset, length)
            actual.should eq(expected), "mismatch at offset=#{offset}, length=#{length}"
          end
        end
      ensure
        File.delete(tmp) if File.exists?(tmp)
      end
    end
  end

  it "matches normal gzip decompression from every checkpoint" do
    SpecZranSupport.with_reference_gzip do |gz_path, plain|
      tmp = Fqix::Zran.build_to_temp(gz_path, 1024_u64)
      checkpoints = Fqix::Zran.read_temp(tmp)

      begin
        checkpoints.each do |checkpoint|
          length = {plain.bytesize - checkpoint.out_offset.to_i, 8192}.min
          actual = SpecZranSupport.read_extract(gz_path, checkpoint, 0_u64, length.to_u64)
          actual.should eq(plain.byte_slice(checkpoint.out_offset.to_i, length))
        end
      ensure
        File.delete(tmp) if File.exists?(tmp)
      end
    end
  end

  it "matches Mark Adler's zran extraction across gzip members" do
    SpecZranSupport.with_reference_multimember_gzip do |gz_path, plain, split|
      span = 1024_u64
      tmp = Fqix::Zran.build_to_temp(gz_path, span)
      checkpoints = Fqix::Zran.read_temp(tmp)

      begin
        offsets = [0, split - 256, split - 1, split, split + 1, split + 256, plain.bytesize - 4096]
        lengths = [1, 128, 4096, 20_000]

        offsets.each do |offset|
          next if offset < 0 || offset >= plain.bytesize

          lengths.each do |length|
            expected = SpecZranSupport.reference_extract(gz_path, span, offset, length)
            actual = SpecZranSupport.crystal_extract(gz_path, checkpoints, offset, length)
            actual.should eq(expected), "mismatch at offset=#{offset}, length=#{length}"
          end
        end
      ensure
        File.delete(tmp) if File.exists?(tmp)
      end
    end
  end

  it "matches Mark Adler's zran extraction across many gzip members" do
    SpecZranSupport.with_reference_multimember_gzip(6) do |gz_path, plain, _split|
      span = plain.bytesize.to_u64 * 2
      tmp = Fqix::Zran.build_to_temp(gz_path, span)
      checkpoints = Fqix::Zran.read_temp(tmp)

      begin
        checkpoints.size.should eq(1)
        offsets = [
          0,
          plain.bytesize // 3,
          plain.bytesize // 2,
          (plain.bytesize * 5) // 6,
          plain.bytesize - 4096,
        ]
        lengths = [128, 4096, 20_000, 70_000]

        offsets.each do |offset|
          lengths.each do |length|
            expected = SpecZranSupport.reference_extract(gz_path, span, offset, length)
            actual = SpecZranSupport.crystal_extract(gz_path, checkpoints, offset, length)
            actual.should eq(expected), "mismatch at offset=#{offset}, length=#{length}"
          end
        end
      ensure
        File.delete(tmp) if File.exists?(tmp)
      end
    end
  end

  it "does not carry checkpoint dictionaries across gzip members" do
    SpecZranSupport.with_reference_multimember_gzip do |gz_path, _plain, split|
      tmp = Fqix::Zran.build_to_temp(gz_path, 1024_u64)
      checkpoints = Fqix::Zran.read_temp(tmp)

      begin
        second_member_checkpoints = checkpoints.select { |checkpoint| checkpoint.out_offset >= split }
        second_member_checkpoints.should_not be_empty

        second_member_checkpoints.each do |checkpoint|
          checkpoint.have.should be <= (checkpoint.out_offset - split).to_u32
        end
      ensure
        File.delete(tmp) if File.exists?(tmp)
      end
    end
  end
end
