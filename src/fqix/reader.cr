require "./fastq"
require "./index"
require "./order"
require "./zran"

module Fqix
  class Reader
    DEFAULT_SCAN_BYTES = 16_u64 * 1024_u64 * 1024_u64

    enum FetchStatus
      Found
      NotFound
      ScanLimitReached
    end

    record FetchResult, status : FetchStatus, record : String?, position : UInt64 do
      def self.found(record : String, position : UInt64 = 0_u64) : FetchResult
        new(FetchStatus::Found, record, position)
      end

      def self.not_found : FetchResult
        new(FetchStatus::NotFound, nil, 0_u64)
      end

      def self.scan_limit_reached : FetchResult
        new(FetchStatus::ScanLimitReached, nil, 0_u64)
      end
    end

    record FetchMatchesResult, status : FetchStatus, matches : Array(Tuple(UInt64, String)) do
      def self.found(matches : Array(Tuple(UInt64, String))) : FetchMatchesResult
        new(FetchStatus::Found, matches)
      end

      def self.not_found : FetchMatchesResult
        new(FetchStatus::NotFound, [] of Tuple(UInt64, String))
      end

      def self.scan_limit_reached(matches : Array(Tuple(UInt64, String)) = [] of Tuple(UInt64, String)) : FetchMatchesResult
        new(FetchStatus::ScanLimitReached, matches)
      end
    end

    record FetchCountResult, status : FetchStatus, count : Int32 do
      def self.found(count : Int32) : FetchCountResult
        new(FetchStatus::Found, count)
      end

      def self.not_found : FetchCountResult
        new(FetchStatus::NotFound, 0)
      end

      def self.scan_limit_reached(count : Int32 = 0) : FetchCountResult
        new(FetchStatus::ScanLimitReached, count)
      end
    end

    def initialize(@gz_path : String, @index : Index)
    end

    def fetch(name : String, scan_bytes : UInt64 = DEFAULT_SCAN_BYTES) : String?
      result = fetch_with_status(name, scan_bytes)
      raise Error.new("scan limit reached before lookup completed: #{name}") if result.status.scan_limit_reached?
      result.status.found? ? result.record : nil
    end

    def fetch_with_status(name : String, scan_bytes : UInt64 = DEFAULT_SCAN_BYTES) : FetchResult
      fetch_many([name], scan_bytes).first
    end

    def fetch_all(name : String, scan_bytes : UInt64 = DEFAULT_SCAN_BYTES) : Array(String)
      fetch_matches(name, scan_bytes).map(&.[1])
    end

    def fetch_matches(name : String, scan_bytes : UInt64 = DEFAULT_SCAN_BYTES) : Array(Tuple(UInt64, String))
      result = fetch_matches_with_status(name, scan_bytes)
      raise Error.new("scan limit reached before lookup completed: #{name}") if result.status.scan_limit_reached?
      result.matches
    end

    def fetch_matches_with_status(name : String, scan_bytes : UInt64 = DEFAULT_SCAN_BYTES) : FetchMatchesResult
      case @index.mode
      in .exact?
        matches = @index.find_exact_candidates(name).compact_map do |candidate|
          fetch_exact_candidate(name, candidate).try { |record| {candidate.record_offset, record} }
        end
        matches.empty? ? FetchMatchesResult.not_found : FetchMatchesResult.found(matches)
      in .sparse?
        fetch_sparse_matches_with_status(name, scan_bytes)
      end
    end

    def fetch_many_matches_with_status(names : Array(String), scan_bytes : UInt64 = DEFAULT_SCAN_BYTES) : Array(FetchMatchesResult)
      case @index.mode
      in .exact?
        fetch_exact_many_matches_with_status(names)
      in .sparse?
        names.map { |name| fetch_sparse_matches_with_status(name, scan_bytes) }
      end
    end

    def count_many_matches_with_status(names : Array(String), scan_bytes : UInt64 = DEFAULT_SCAN_BYTES) : Array(FetchCountResult)
      case @index.mode
      in .exact?
        count_exact_many_matches_with_status(names)
      in .sparse?
        names.map do |name|
          result = fetch_sparse_matches_with_status(name, scan_bytes)
          case result.status
          in .found?
            FetchCountResult.found(result.matches.size)
          in .not_found?
            FetchCountResult.not_found
          in .scan_limit_reached?
            FetchCountResult.scan_limit_reached(result.matches.size)
          end
        end
      end
    end

    def fetch_many(names : Array(String), scan_bytes : UInt64 = DEFAULT_SCAN_BYTES) : Array(FetchResult)
      fetch_many_matches_with_status(names, scan_bytes).map do |result|
        if match = result.matches.first?
          FetchResult.new(result.status.found? ? FetchStatus::Found : result.status, match[1], match[0])
        else
          FetchResult.new(result.status, nil, 0_u64)
        end
      end
    end

    private def fetch_sparse_with_status(name : String, scan_bytes : UInt64) : FetchResult
      result = fetch_sparse_matches_with_status(name, scan_bytes)
      if match = result.matches.first?
        FetchResult.new(result.status.found? ? FetchStatus::Found : result.status, match[1], match[0])
      else
        FetchResult.new(result.status, nil, 0_u64)
      end
    end

    private def fetch_sparse_matches_with_status(name : String, scan_bytes : UInt64) : FetchMatchesResult
      normalized = @index.normalize_query(name)
      return FetchMatchesResult.not_found unless entry = @index.find_floor_name(normalized, normalized: true)

      cp = @index.checkpoint(entry.checkpoint_id.to_i)
      scanner = RecordScanner.new(normalized, entry.uncompressed_offset, @index.order_mode)
      limit_reached = Zran.extract_to(@gz_path, cp, entry.delta, scan_bytes, ->(chunk : Bytes) { scanner.feed(chunk) })
      scanner.finish unless limit_reached
      scanner.result(limit_reached)
    end

    private record ExactBatchCandidate,
      query_index : Int32,
      query : String,
      candidate : ExactCandidate

    private def fetch_exact_many_matches_with_status(names : Array(String)) : Array(FetchMatchesResult)
      if @index.checkpoint_metas.empty?
        raise Error.new("invalid fqix index checkpoint count") unless names.empty?
      end

      matches_by_query = Array(Array(Tuple(UInt64, String))).new(names.size) { [] of Tuple(UInt64, String) }
      candidates_by_checkpoint = Hash(Int32, Array(ExactBatchCandidate)).new do |hash, checkpoint_id|
        hash[checkpoint_id] = [] of ExactBatchCandidate
      end

      names.each_with_index do |name, query_index|
        @index.find_exact_candidates(name).each do |candidate|
          checkpoint_id = Index.checkpoint_for(@index.checkpoint_metas, candidate.record_offset)
          candidates_by_checkpoint[checkpoint_id] << ExactBatchCandidate.new(query_index, name, candidate)
        end
      end

      candidates_by_checkpoint.each do |checkpoint_id, candidates|
        fetch_exact_checkpoint_batch(checkpoint_id, candidates, matches_by_query)
      end

      matches_by_query.map do |matches|
        matches.sort_by!(&.[0])
        matches.empty? ? FetchMatchesResult.not_found : FetchMatchesResult.found(matches)
      end
    end

    private def count_exact_many_matches_with_status(names : Array(String)) : Array(FetchCountResult)
      if @index.checkpoint_metas.empty?
        raise Error.new("invalid fqix index checkpoint count") unless names.empty?
      end

      counts = Array(Int32).new(names.size, 0)
      candidates_by_checkpoint = Hash(Int32, Array(ExactBatchCandidate)).new do |hash, checkpoint_id|
        hash[checkpoint_id] = [] of ExactBatchCandidate
      end

      names.each_with_index do |name, query_index|
        @index.find_exact_candidates(name).each do |candidate|
          checkpoint_id = Index.checkpoint_for(@index.checkpoint_metas, candidate.record_offset)
          candidates_by_checkpoint[checkpoint_id] << ExactBatchCandidate.new(query_index, name, candidate)
        end
      end

      candidates_by_checkpoint.each do |checkpoint_id, candidates|
        count_exact_checkpoint_batch(checkpoint_id, candidates, counts)
      end

      counts.map { |count| count == 0 ? FetchCountResult.not_found : FetchCountResult.found(count) }
    end

    private def fetch_exact_checkpoint_batch(checkpoint_id : Int32,
                                             candidates : Array(ExactBatchCandidate),
                                             matches_by_query : Array(Array(Tuple(UInt64, String)))) : Nil
      return if candidates.empty?

      candidates.sort_by!(&.candidate.record_offset)
      min_offset = candidates.first.candidate.record_offset
      max_end = candidates.max_of { |entry| entry.candidate.record_offset + entry.candidate.record_size.to_u64 }
      checkpoint = @index.checkpoint(checkpoint_id)
      delta = min_offset - @index.checkpoint_metas[checkpoint_id].out_offset
      output = IO::Memory.new

      Zran.extract_to(@gz_path, checkpoint, delta, max_end - min_offset, ->(chunk : Bytes) {
        output.write(chunk)
        true
      })

      block = output.to_slice
      candidates.each do |entry|
        candidate = entry.candidate
        record = exact_record_slice(block, min_offset, candidate)
        if verified_exact_record?(entry.query, candidate.record_offset, record)
          matches_by_query[entry.query_index] << {candidate.record_offset, String.new(record)}
        end
      end
    end

    private def count_exact_checkpoint_batch(checkpoint_id : Int32,
                                             candidates : Array(ExactBatchCandidate),
                                             counts : Array(Int32)) : Nil
      return if candidates.empty?

      candidates.sort_by!(&.candidate.record_offset)
      min_offset = candidates.first.candidate.record_offset
      max_end = candidates.max_of { |entry| entry.candidate.record_offset + entry.candidate.record_size.to_u64 }
      checkpoint = @index.checkpoint(checkpoint_id)
      delta = min_offset - @index.checkpoint_metas[checkpoint_id].out_offset
      output = IO::Memory.new

      Zran.extract_to(@gz_path, checkpoint, delta, max_end - min_offset, ->(chunk : Bytes) {
        output.write(chunk)
        true
      })

      block = output.to_slice
      candidates.each do |entry|
        candidate = entry.candidate
        record = exact_record_slice(block, min_offset, candidate)
        counts[entry.query_index] += 1 if verified_exact_record?(entry.query, candidate.record_offset, record)
      end
    end

    private def fetch_exact_candidate(query : String, candidate : ExactCandidate) : String?
      if @index.checkpoint_metas.empty?
        raise Error.new("invalid fqix index checkpoint count")
      end
      checkpoint_id = Index.checkpoint_for(@index.checkpoint_metas, candidate.record_offset)
      checkpoint = @index.checkpoint(checkpoint_id)
      delta = candidate.record_offset - @index.checkpoint_metas[checkpoint_id].out_offset
      output = IO::Memory.new
      Zran.extract_to(@gz_path, checkpoint, delta, candidate.record_size.to_u64, ->(chunk : Bytes) {
        output.write(chunk)
        true
      })
      record = output.to_slice
      verified_exact_record?(query, candidate.record_offset, record) ? String.new(record) : nil
    end

    private def exact_record_slice(block : Bytes, min_offset : UInt64, candidate : ExactCandidate) : Bytes
      start = (candidate.record_offset - min_offset).to_i
      size = candidate.record_size.to_i
      if start < 0 || size < 0 || start + size > block.size
        raise Error.new("index/input mismatch: truncated FASTQ record at #{candidate.record_offset}")
      end
      block[start, size]
    end

    private def verified_exact_record?(query : String, record_offset : UInt64, record : Bytes) : Bool
      newline = record.index('\n'.ord.to_u8)
      header = newline ? record[0, newline + 1] : record
      raise Error.new("index/input mismatch: empty FASTQ record at #{record_offset}") if header.empty?
      actual = Fastq.name_from_header(String.new(header))
      expected = @index.normalize_query(query)
      actual == expected
    end

    # Streaming, four-line FASTQ matcher for sparse mode. It scans from the
    # nearest anchor through the equal-name run so duplicate read names are not
    # silently truncated.
    private class RecordScanner
      def initialize(@query : String, @base_offset : UInt64, @order_mode : OrderMode)
        @matches = [] of Tuple(UInt64, String)
        @resolved = false
        @buf = IO::Memory.new
        @header = IO::Memory.new
        @framer = Fastq::StreamParser.new(
          ->(segment : Bytes, line_in_record : Int32, _line_start : UInt64) {
            @buf.write(segment)
            @header.write(segment) if line_in_record == 0
          },
          ->(record_start : UInt64, _record_size : UInt64) {
            decide(record_start)
            !done?
          }
        )
      end

      def feed(chunk : Bytes) : Bool
        @framer.feed(chunk)
      end

      def finish : Nil
        @framer.finish(strict: false) unless done?
      end

      def result(limit_reached : Bool) : FetchMatchesResult
        if limit_reached && !@resolved
          return FetchMatchesResult.scan_limit_reached(@matches)
        end
        @matches.empty? ? FetchMatchesResult.not_found : FetchMatchesResult.found(@matches)
      end

      private def decide(record_start : UInt64) : Nil
        name = Fastq.name_from_header(@header.to_s)
        order = Order.compare(name, @query, @order_mode)
        if order == 0 && name == @query
          @matches << {@base_offset + record_start, @buf.to_s}
        elsif order > 0
          @resolved = true
        end

        @buf.clear
        @header.clear
      end

      private def done? : Bool
        @resolved
      end
    end
  end
end
