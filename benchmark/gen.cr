#!/usr/bin/env crystal
#
# Generate a synthetic .fastq.gz that mimics a real archive's compressibility.
# See fastq_gen.cr for the data model.
#
#   crystal run benchmark/gen.cr -- --preset srr --records 200000
#   crystal run benchmark/gen.cr -- --preset srr --records 1000000 -o benchmark/out/big.fastq.gz
#
# Without -o the file is written under --out-dir using a descriptive name.

require "file_utils"
require "option_parser"
require "./fastq_gen"

module Benchmark::Gen
  extend self

  def run(argv : Array(String)) : Nil
    preset = "srr"
    records = nil.as(Int32?)
    read_len = nil.as(Int32?)
    accession = nil.as(String?)
    seed = FastqGen::DEFAULT_SEED
    out_dir = "benchmark/out"
    output = nil.as(String?)

    parser = OptionParser.new do |opts|
      opts.banner = "Usage: crystal run benchmark/gen.cr -- [options]"
      opts.on("--preset NAME", "Data preset: #{FastqGen::PRESET_NAMES.join(", ")} [srr]") { |v| preset = v }
      opts.on("--records N", "Record count [preset default]") { |v| records = parse_i32(v, "records") }
      opts.on("--read-len N", "Read length [preset default]") { |v| read_len = parse_i32(v, "read length") }
      opts.on("--accession NAME", "Accession used in read names [SRR000000]") { |v| accession = v }
      opts.on("--seed N", "RNG seed [#{FastqGen::DEFAULT_SEED}]") { |v| seed = parse_u64(v, "seed") }
      opts.on("--out-dir DIR", "Directory for the generated file [benchmark/out]") { |v| out_dir = v }
      opts.on("-o PATH", "--output PATH", "Explicit output path (overrides --out-dir)") { |v| output = v }
      opts.on("-h", "--help", "Show this help") do
        puts opts
        exit
      end
    end
    parser.parse(argv)

    spec =
      begin
        FastqGen.preset(preset, records, read_len, accession, seed)
      rescue ex : ArgumentError
        abort ex.message
      end
    abort "--records must be greater than zero" if spec.records <= 0
    abort "--read-len must be greater than zero" if spec.read_len <= 0

    explicit = output
    path = explicit ? explicit : File.join(out_dir, FastqGen.filename(spec))
    FileUtils.mkdir_p(File.dirname(path))

    stats = FastqGen.write(spec, path)
    puts path
    STDERR.puts "records=#{stats.records} uncompressed=#{stats.uncompressed_bytes} " \
                "gz=#{stats.gz_bytes} ratio=#{"%.2f" % stats.ratio}x"
  end

  private def parse_i32(value : String, label : String) : Int32
    value.to_i? || abort("invalid #{label}: #{value.inspect}")
  end

  private def parse_u64(value : String, label : String) : UInt64
    value.to_u64? || abort("invalid #{label}: #{value.inspect}")
  end
end

Benchmark::Gen.run(ARGV)
