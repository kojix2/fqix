#!/usr/bin/env crystal
#
# Measures exact-index size and lookup behaviour, splitting the index into its
# lookup table (MPHF + slots + overflow) and its zran checkpoint windows.
#
# Synthetic FASTQ is produced by fastq_gen.cr, which mimics the compressibility
# of real SRA/DRA archives (repeated `+` header, autocorrelated quality, pooled
# sequence). That keeps `index_pct_of_gz` comparable to real data instead of the
# inflated values uniform-random FASTQ would give.
#
# Since exact v2.3 the checkpoint windows are deflate-compressed on disk, so the
# window section is measured from the actual file (not `n * 32 KiB`); the
# raw-equivalent size and the achieved window compression ratio are reported too.
#
#   crystal run benchmark/exact_size.cr -- --profile srr --records 200000
#   crystal run benchmark/exact_size.cr -- --input reads.fastq.gz

require "file_utils"
require "option_parser"

require "../src/fqix/index"
require "../src/fqix/reader"
require "./fastq_gen"

module ExactSizeExperiment
  extend self

  OUT_DIR      = "benchmark/out"
  RESULTS_PATH = "benchmark/out/exact_size.tsv"

  V20_PER_RECORD = 48_u64
  V21_PER_RECORD = Fqix::IndexFormat::ENTRY_SIZE

  TSV_HEADER = [
    "run_at",
    "dataset",
    "profile",
    "records",
    "distinct_keys",
    "read_len",
    "name_repeat",
    "checkpoint_span",
    "uncompressed_bytes",
    "gz_bytes",
    "index_bytes",
    "index_pct_of_gz",
    "index_bpr",
    "lookup_bytes",
    "lookup_bpr",
    "mphf_bytes",
    "slot_bytes",
    "overflow_bytes",
    "overflow_entries",
    "window_bytes",
    "raw_window_bytes",
    "window_compress_ratio",
    "checkpoint_meta_bytes",
    "checkpoints",
    "header_bytes",
    "v20_lookup_bytes",
    "v21_lookup_bytes",
    "v22_lookup_bytes",
    "v22_vs_v20_pct",
    "build_seconds",
    "build_mibps",
    "guard_fp_rate",
    "pos_lookup_us",
    "neg_lookup_us",
    "input_names_sorted",
    "fastq_gz_path",
    "index_path",
  ]

  record Config,
    profile : String = "srr",
    records : Int32 = 200_000,
    read_len : Int32? = nil,
    name_repeat : Int32 = 1,
    checkpoint_span : UInt64 = Fqix::Index::DEFAULT_CHECKPOINT_SPAN,
    out_dir : String = OUT_DIR,
    results_path : String = RESULTS_PATH,
    input : String? = nil,
    sample : Int32 = 2_000,
    probes : Int32 = 20_000,
    keep : Bool = true,
    stdout_header : Bool = true

  # Stats gathered from a single decompression pass over the FASTQ.
  record ScanStats,
    record_count : UInt64,
    name_bytes : UInt64,
    uncompressed_bytes : UInt64,
    present_names : Array(String)

  def run(argv : Array(String)) : Nil
    config = parse(argv)
    FileUtils.mkdir_p(config.out_dir)
    FileUtils.mkdir_p(File.dirname(config.results_path))

    gz_path, generated_read_len = resolve_input(config)
    generated = config.input.nil?
    index_path = generated ? "#{gz_path}.fqix" : File.join(config.out_dir, "#{File.basename(gz_path)}.fqix")

    started = Time.instant
    index = Fqix::Index.build(
      gz_path,
      checkpoint_span: config.checkpoint_span,
      mode: Fqix::IndexMode::Exact
    )
    build_seconds = (Time.instant - started).total_seconds
    index.write(index_path)

    stats = scan_stats(gz_path, config.sample)
    guard_fp_rate, neg_lookup_us = probe_absent(index, gz_path, config.probes)
    pos_lookup_us = probe_present(index, gz_path, stats.present_names)

    row = result_row(
      config, gz_path, index_path, index, stats,
      generated_read_len, build_seconds,
      guard_fp_rate, pos_lookup_us, neg_lookup_us
    )
    append_tsv(config.results_path, row)
    print_tsv_header if config.stdout_header
    puts tsv_line(row)
    STDERR.puts "wrote #{config.results_path}"
  ensure
    cleanup(config, gz_path, index_path)
  end

  private def cleanup(config : Config?, gz_path : String?, index_path : String?) : Nil
    return unless config
    return if config.keep
    if (path = gz_path) && config.input.nil? && File.exists?(path)
      File.delete(path)
    end
    if (path = index_path) && File.exists?(path)
      File.delete(path)
    end
  end

  # Returns {gz_path, read_len}. Generates a synthetic FASTQ unless --input given.
  private def resolve_input(config : Config) : Tuple(String, Int32?)
    if path = config.input
      return {path, config.read_len}
    end
    spec = Benchmark::FastqGen.preset(config.profile, config.records, config.read_len)
    path = File.join(
      config.out_dir,
      "#{config.profile}-n#{config.records}-l#{spec.read_len}-r#{config.name_repeat}-span#{config.checkpoint_span}.fastq.gz"
    )
    Benchmark::FastqGen.write(spec, path)
    {path, spec.read_len}
  end

  private def parse(argv : Array(String)) : Config
    profile = "srr"
    records = 200_000
    read_len = nil.as(Int32?)
    name_repeat = 1
    checkpoint_span = Fqix::Index::DEFAULT_CHECKPOINT_SPAN
    out_dir = OUT_DIR
    results_path = RESULTS_PATH
    input = nil.as(String?)
    sample = 2_000
    probes = 20_000
    keep = true
    stdout_header = true

    parser = OptionParser.new do |opts|
      opts.banner = "Usage: crystal run benchmark/exact_size.cr -- [options]"
      opts.on("--profile NAME", "Data preset: #{Benchmark::FastqGen::PRESET_NAMES.join(", ")} [srr]") { |v| profile = v }
      opts.on("--records N", "Synthetic record count [200000]") { |v| records = parse_i32(v, "records") }
      opts.on("--read-len N", "Synthetic read length; preset default when omitted") { |v| read_len = parse_i32(v, "read length") }
      opts.on("--name-repeat K", "Emit each read name K times to exercise overflow slots [1]") { |v| name_repeat = parse_i32(v, "name repeat") }
      opts.on("--checkpoint-span BYTES", "Uncompressed checkpoint span, minimum #{Fqix::Zran::WINDOW_SIZE} [#{checkpoint_span}]") { |v| checkpoint_span = parse_u64(v, "checkpoint span") }
      opts.on("--out-dir DIR", "Directory for generated FASTQ/index files [#{OUT_DIR}]") { |v| out_dir = v }
      opts.on("--results PATH", "Append TSV results to PATH [#{RESULTS_PATH}]") { |v| results_path = v }
      opts.on("--input PATH", "Measure an existing .fastq.gz instead of generating one") { |v| input = v }
      opts.on("--sample N", "Present-name lookup sample size [2000]") { |v| sample = parse_i32(v, "sample") }
      opts.on("--probes N", "Absent-name probe count for guard/negative lookup [20000]") { |v| probes = parse_i32(v, "probes") }
      opts.on("--cleanup", "Delete generated .fastq.gz and .fqix files after measuring") { keep = false }
      opts.on("--no-header", "Do not print the TSV header to stdout") { stdout_header = false }
      opts.on("-h", "--help", "Show this help") do
        puts opts
        exit
      end
    end
    parser.parse(argv)

    validate!(profile, records, name_repeat, read_len, checkpoint_span, sample, probes, input)
    Config.new(profile, records, read_len, name_repeat, checkpoint_span,
      out_dir, results_path, input, sample, probes, keep, stdout_header)
  end

  private def validate!(profile, records, name_repeat, read_len, checkpoint_span, sample, probes, input) : Nil
    unless Benchmark::FastqGen::PRESET_NAMES.includes?(profile)
      abort "unknown --profile #{profile.inspect}; expected #{Benchmark::FastqGen::PRESET_NAMES.join(", ")}"
    end
    abort "--records must be greater than zero" if records <= 0
    abort "--name-repeat must be greater than zero" if name_repeat <= 0
    abort "--read-len must be greater than zero" if read_len.try { |value| value <= 0 }
    if checkpoint_span < Fqix::Zran::WINDOW_SIZE
      abort "--checkpoint-span must be at least #{Fqix::Zran::WINDOW_SIZE} bytes"
    end
    abort "--sample must not be negative" if sample < 0
    abort "--probes must not be negative" if probes < 0
    if path = input
      abort "input does not exist: #{path}" unless File.exists?(path)
    end
  end

  private def parse_i32(value : String, label : String) : Int32
    value.to_i? || abort("invalid #{label}: #{value.inspect}")
  end

  private def parse_u64(value : String, label : String) : UInt64
    value.to_u64? || abort("invalid #{label}: #{value.inspect}")
  end

  # Single decompression pass: record/name byte totals (for the v2.0 estimate)
  # plus a sample of present names for positive-lookup timing.
  private def scan_stats(gz_path : String, sample_limit : Int32) : ScanStats
    count = 0_u64
    name_bytes = 0_u64
    uncompressed = 0_u64
    present = [] of String
    header = IO::Memory.new

    parser = Fqix::Fastq::StreamParser.new(
      ->(segment : Bytes, line_in_record : Int32, _line_start : UInt64) {
        header.write(segment) if line_in_record == 0
        nil
      },
      ->(_record_start : UInt64, record_size : UInt64) {
        name = Fqix::Fastq.name_from_header(header.to_s)
        count += 1
        name_bytes += name.bytesize.to_u64
        uncompressed += record_size
        present << name if present.size < sample_limit
        header.clear
        true
      }
    )

    File.open(gz_path) do |file|
      Compress::Gzip::Reader.open(file) do |gzip|
        buffer = Bytes.new(64 * 1024)
        while (read = gzip.read(buffer)) > 0
          parser.feed(buffer[0, read])
        end
      end
    end
    parser.finish

    ScanStats.new(count, name_bytes, uncompressed, present)
  end

  # Fraction of known-absent names whose guard byte still admits a candidate
  # (i.e. would reach FASTQ I/O before header verification rejects them), plus
  # mean negative-lookup latency through the full reader.
  private def probe_absent(index : Fqix::Index, gz_path : String, probes : Int32) : Tuple(Float64, Float64)
    return {0.0, 0.0} if probes == 0
    reader = Fqix::Reader.new(gz_path, index)
    guard_admitted = 0_u64
    elapsed = Time::Span.zero
    probes.times do |i|
      name = "absent_probe_#{i}"
      guard_admitted += 1 unless index.find_exact_candidates(name).empty?
      started = Time.instant
      reader.fetch(name)
      elapsed += Time.instant - started
    end
    {guard_admitted.to_f64 / probes.to_f64, elapsed.total_microseconds / probes.to_f64}
  end

  private def probe_present(index : Fqix::Index, gz_path : String, names : Array(String)) : Float64
    return 0.0 if names.empty?
    reader = Fqix::Reader.new(gz_path, index)
    elapsed = Time::Span.zero
    names.each do |name|
      started = Time.instant
      reader.fetch(name)
      elapsed += Time.instant - started
    end
    elapsed.total_microseconds / names.size.to_f64
  end

  private def result_row(config : Config,
                         gz_path : String,
                         index_path : String,
                         index : Fqix::Index,
                         stats : ScanStats,
                         read_len : Int32?,
                         build_seconds : Float64,
                         guard_fp_rate : Float64,
                         pos_lookup_us : Float64,
                         neg_lookup_us : Float64) : Array(String)
    gz_bytes = File.size(gz_path).to_u64
    index_bytes = File.size(index_path).to_u64
    record_count = index.record_count
    checkpoints = index.checkpoint_metas.size.to_u64

    mphf_bytes = index.mphf.try(&.to_slice.size.to_u64) || 0_u64
    slot_bytes = index.slots.size.to_u64 * Fqix::IndexFormat::SLOT_SIZE
    overflow_bytes = index.overflows.size.to_u64 * Fqix::IndexFormat::OVERFLOW_ENTRY_SIZE
    checkpoint_meta_bytes = checkpoints * Fqix::IndexFormat::CHECKPOINT_META_SIZE
    header_bytes = Fqix::IndexFormat::V2_2_HEADER_SIZE + index.source_path.bytesize.to_u64
    lookup_bytes = mphf_bytes + slot_bytes + overflow_bytes

    # The on-disk window section sits after every other section; measuring it by
    # subtraction captures the deflate-compressed size (v2.3) rather than assuming
    # one raw 32 KiB window per checkpoint.
    windows_offset = header_bytes + lookup_bytes + checkpoint_meta_bytes
    window_bytes = index_bytes - windows_offset
    raw_window_bytes = checkpoints * Fqix::Zran::WINDOW_SIZE.to_u64

    # Sanity: the compressed window section cannot exceed the raw size plus a small
    # per-window deflate overhead, and the sections must reconstruct the file.
    unless windows_offset <= index_bytes && window_bytes <= raw_window_bytes + checkpoints * 64
      raise "window section accounting mismatch: windows_offset=#{windows_offset} window_bytes=#{window_bytes} index_bytes=#{index_bytes}"
    end

    v20_lookup_bytes = record_count * V20_PER_RECORD + stats.name_bytes
    v21_lookup_bytes = record_count * V21_PER_RECORD
    v22_lookup_bytes = lookup_bytes

    build_mibps =
      if build_seconds > 0
        stats.uncompressed_bytes.to_f64 / (1024.0 * 1024.0) / build_seconds
      else
        0.0
      end

    [
      Time.utc.to_rfc3339,
      config.input ? File.basename(gz_path) : config.profile,
      config.profile,
      record_count.to_s,
      index.slots.size.to_s,
      read_len.try(&.to_s) || "",
      config.name_repeat.to_s,
      config.checkpoint_span.to_s,
      stats.uncompressed_bytes.to_s,
      gz_bytes.to_s,
      index_bytes.to_s,
      percent(index_bytes, gz_bytes),
      bpr(index_bytes, record_count),
      lookup_bytes.to_s,
      bpr(lookup_bytes, record_count),
      mphf_bytes.to_s,
      slot_bytes.to_s,
      overflow_bytes.to_s,
      index.overflows.size.to_s,
      window_bytes.to_s,
      raw_window_bytes.to_s,
      ratio(raw_window_bytes, window_bytes),
      checkpoint_meta_bytes.to_s,
      checkpoints.to_s,
      header_bytes.to_s,
      v20_lookup_bytes.to_s,
      v21_lookup_bytes.to_s,
      v22_lookup_bytes.to_s,
      percent(v22_lookup_bytes, v20_lookup_bytes),
      "%.6f" % build_seconds,
      "%.2f" % build_mibps,
      "%.6f" % guard_fp_rate,
      "%.3f" % pos_lookup_us,
      "%.3f" % neg_lookup_us,
      index.input_names_sorted?.to_s,
      gz_path,
      index_path,
    ]
  end

  private def append_tsv(path : String, row : Array(String)) : Nil
    write_header = !File.exists?(path) || File.size(path) == 0
    File.open(path, "a") do |file|
      file.puts TSV_HEADER.join('\t') if write_header
      file.puts tsv_line(row)
    end
  end

  private def print_tsv_header : Nil
    puts TSV_HEADER.join('\t')
  end

  private def percent(numerator : UInt64, denominator : UInt64) : String
    return "" if denominator == 0
    "%.2f" % (numerator.to_f64 * 100.0 / denominator.to_f64)
  end

  private def ratio(numerator : UInt64, denominator : UInt64) : String
    return "" if denominator == 0
    "%.2f" % (numerator.to_f64 / denominator.to_f64)
  end

  private def bpr(bytes : UInt64, records : UInt64) : String
    return "" if records == 0
    "%.4f" % (bytes.to_f64 / records.to_f64)
  end

  private def tsv_line(values : Array(String)) : String
    values.map { |value| tsv(value) }.join('\t')
  end

  private def tsv(value : String) : String
    value
      .gsub('\\', "\\\\")
      .gsub('\t', "\\t")
      .gsub('\n', "\\n")
      .gsub('\r', "\\r")
  end
end

ExactSizeExperiment.run(ARGV)
