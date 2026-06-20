# Measure how well zran checkpoint windows compress, independent of the index
# format. Random access needs each window to stay independently addressable, so
# the realistic number is per-window deflate (this is what v1.2/v2.3 stores).
# Whole-block deflate is reported only as an unreachable lower bound.
#
#   crystal run benchmark/window_compression.cr -- path/to/file.fastq.gz.fqix ...
require "../src/fqix/index"
require "compress/deflate"

ARGV.each do |path|
  idx = Fqix::Index.read(path)
  n = idx.checkpoint_metas.size
  raw = 0_i64
  per_window = 0_i64
  smallest = Int32::MAX
  largest = 0
  all = IO::Memory.new
  n.times do |i|
    w = idx.checkpoint_window(i)
    raw += w.size
    all.write(w)
    buf = IO::Memory.new
    Compress::Deflate::Writer.open(buf, level: Compress::Deflate::BEST_COMPRESSION) { |deflater| deflater.write(w) }
    c = buf.size
    per_window += c
    smallest = c if c < smallest
    largest = c if c > largest
  end
  whole = IO::Memory.new
  Compress::Deflate::Writer.open(whole, level: Compress::Deflate::BEST_COMPRESSION) { |deflater| deflater.write(all.to_slice) }

  pct = ->(num : Int64, den : Int64) { den == 0 ? 0.0 : num * 100.0 / den }
  puts "#{File.basename(path)}"
  puts "  windows=#{n} raw=#{raw} (#{(raw / 1048576.0).round(1)} MB)"
  puts "  per-window deflate = #{per_window} (#{(per_window / 1048576.0).round(1)} MB)  -> #{pct.call(per_window, raw).round(1)}% of raw  (#{(raw.to_f / per_window).round(2)}x)"
  puts "  whole-block deflate = #{whole.size} (#{(whole.size / 1048576.0).round(1)} MB)  -> #{pct.call(whole.size.to_i64, raw).round(1)}% of raw  (lower bound, not random-accessible)"
  puts "  per-window compressed size: min=#{smallest} max=#{largest} avg=#{(per_window / n)}"
end
