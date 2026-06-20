require "compress/gzip"

# Synthetic FASTQ generator for fqix benchmarks.
#
# Uniform-random FASTQ compresses at ~3x, but real short-read SRA/DRA archives
# compress at ~5-6x. The gap matters because `index / .gz` ratios scale with the
# source compression ratio, so benchmarking against random data understates how
# large an index looks next to a real file. This generator reproduces the three
# structural properties that make real archives compress well:
#
#   1. the `+` separator repeats the full header (old SRA/DRA dumps), which gzip
#      back-references almost for free;
#   2. base-call quality is autocorrelated (long runs of similar Phred values),
#      not independent per base;
#   3. reads are substrings of a shared sequence pool, so they share content, and
#      a fraction carry `N` runs like real low-quality regions.
#
# Output is deterministic for a given `Spec` (seeded RNG), so a benchmark run is
# reproducible and diffable. Presets approximate common datasets; every field is
# tunable for ad-hoc experiments.
module Benchmark
  module FastqGen
    extend self

    BASES  = "ACGT".bytes
    N_BYTE = 'N'.ord.to_u8
    # Phred+33 quality range used by the quality models.
    QUAL_MIN =  2
    QUAL_MAX = 40
    # Default RNG seed (same constant the JDK/glibc use); keeps runs byte-stable.
    DEFAULT_SEED = 0x5DEECE66D_u64

    enum NameStyle
      Illumina
      Srr
      LongRead
    end

    enum PlusLine
      Bare         # "+"
      RepeatHeader # "+<header>" (old SRA/DRA style, highly compressible)
    end

    enum SeqModel
      Random # uniform ACGT (sequence is near-incompressible)
      Pooled # substrings of a shared pool plus occasional N runs (real-ish)
    end

    enum QualModel
      Uniform # independent per base (compresses poorly)
      Runs    # autocorrelated random walk (real-ish, compresses well)
    end

    record Spec,
      records : Int32,
      read_len : Int32,
      name_style : NameStyle,
      plus_line : PlusLine,
      seq_model : SeqModel,
      qual_model : QualModel,
      accession : String,
      seed : UInt64

    record Stats, records : Int64, uncompressed_bytes : Int64, gz_bytes : Int64 do
      def ratio : Float64
        gz_bytes == 0 ? 0.0 : uncompressed_bytes.to_f64 / gz_bytes.to_f64
      end
    end

    PRESET_NAMES = %w[srr illumina longread]

    # A named starting point. `srr` mimics a real short-read archive (repeated
    # `+` header, pooled sequence with N runs, run-length quality) and lands near
    # 5-6x compression; `illumina` and `longread` use a bare `+` like modern tools.
    def preset(name : String,
               records : Int32? = nil,
               read_len : Int32? = nil,
               accession : String? = nil,
               seed : UInt64 = DEFAULT_SEED) : Spec
      default_records, default_read_len, style, plus =
        case name
        when "srr"      then {200_000, 76, NameStyle::Srr, PlusLine::RepeatHeader}
        when "illumina" then {200_000, 150, NameStyle::Illumina, PlusLine::Bare}
        when "longread" then {8_000, 10_000, NameStyle::LongRead, PlusLine::Bare}
        else                 raise ArgumentError.new("unknown preset #{name.inspect}; expected #{PRESET_NAMES.join(", ")}")
        end

      Spec.new(
        records || default_records, read_len || default_read_len,
        style, plus, SeqModel::Pooled, QualModel::Runs,
        accession || "SRR000000", seed)
    end

    # Deterministic, descriptive filename for a spec.
    def filename(spec : Spec) : String
      "#{spec.name_style.to_s.downcase}-n#{spec.records}-l#{spec.read_len}.fastq.gz"
    end

    # Writes a gzip-compressed FASTQ to `path`; returns size statistics.
    def write(spec : Spec, path : String) : Stats
      uncompressed = 0_i64
      File.open(path, "wb") do |file|
        Compress::Gzip::Writer.open(file) do |gzip|
          uncompressed = write_io(spec, gzip)
        end
      end
      Stats.new(spec.records.to_i64, uncompressed, File.size(path).to_i64)
    end

    # Writes the raw (uncompressed) FASTQ body to `io`; returns the byte count.
    def write_io(spec : Spec, io : IO) : Int64
      rng = Random.new(spec.seed)
      pool = build_pool(spec, rng)
      seq = Bytes.new(spec.read_len)
      qual = Bytes.new(spec.read_len)
      qstate = (QUAL_MIN + QUAL_MAX) // 2
      bytes = 0_i64

      spec.records.times do |index|
        fill_seq(spec, rng, pool, seq)
        qstate = fill_qual(spec, rng, qual, qstate)
        header = header_for(spec, index)
        bytes += write_record(io, header, seq, qual, spec.plus_line)
      end
      bytes
    end

    # A shared sequence pool so reads share substrings (Pooled model). Sized large
    # enough to avoid trivial repetition but small enough for realistic overlap.
    private def build_pool(spec : Spec, rng : Random) : Bytes
      return Bytes.empty if spec.seq_model.random?
      size = {spec.read_len * 4, 524_288}.max
      pool = Bytes.new(size)
      pool.size.times { |i| pool[i] = BASES[rng.rand(4)] }
      pool
    end

    private def fill_seq(spec : Spec, rng : Random, pool : Bytes, seq : Bytes) : Nil
      case spec.seq_model
      in .random?
        seq.size.times { |i| seq[i] = BASES[rng.rand(4)] }
      in .pooled?
        start = pool.size > seq.size ? rng.rand(pool.size - seq.size) : 0
        seq.size.times { |i| seq[i] = pool[start + i] }
        # ~12% of reads carry an N run, like real low-quality stretches.
        if rng.rand(100) < 12
          run = rng.rand(1..({seq.size // 3, 1}.max))
          at = rng.rand(0..(seq.size - run))
          run.times { |i| seq[at + i] = N_BYTE }
        end
      end
    end

    # Returns the updated quality state so runs span record boundaries naturally.
    private def fill_qual(spec : Spec, rng : Random, qual : Bytes, state : Int32) : Int32
      case spec.qual_model
      in .uniform?
        qual.size.times { |i| qual[i] = (33 + QUAL_MIN + rng.rand(QUAL_MAX - QUAL_MIN + 1)).to_u8 }
        state
      in .runs?
        qual.size.times do |i|
          # Mostly hold the current value; occasionally step. Autocorrelation
          # gives the long identical runs that real quality strings compress by.
          if rng.rand(100) >= 92
            state = (state + rng.rand(-3..3)).clamp(QUAL_MIN, QUAL_MAX)
          end
          qual[i] = (33 + state).to_u8
        end
        state
      end
    end

    # Header text without the leading `@` or trailing newline. The first token
    # (up to the first space) is the read name fqix indexes.
    private def header_for(spec : Spec, index : Int32) : String
      case spec.name_style
      in .srr?
        lane = (index % 8) + 1
        tile = 1101 + (index // 10_000) % 200
        x = (index &* 37) % 30_000
        y = (index &* 53) % 30_000
        "#{spec.accession}.#{index + 1} HWUSI-EAS100R:#{lane}:#{tile}:#{x}:#{y} length=#{spec.read_len}"
      in .illumina?
        lane = (index % 8) + 1
        tile = 1101 + (index // 10_000) % 200
        x = (index &* 37) % 30_000
        y = (index &* 53) % 30_000
        "M00176:49:000000000-A3JHG:#{lane}:#{tile}:#{x}:#{y} 1:N:0:1"
      in .long_read?
        "m64011_190830_220126/#{index + 1}/ccs"
      end
    end

    private def write_record(io : IO, header : String, seq : Bytes, qual : Bytes, plus_line : PlusLine) : Int64
      io << '@' << header << '\n'
      io.write(seq)
      io << '\n'
      plus_bytes =
        case plus_line
        in .bare?
          io << "+\n"
          2_i64
        in .repeat_header?
          io << '+' << header << '\n'
          (2 + header.bytesize).to_i64
        end
      io.write(qual)
      io << '\n'
      (2 + header.bytesize).to_i64 + (seq.size + 1) + plus_bytes + (qual.size + 1)
    end
  end
end
