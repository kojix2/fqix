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

    def fetch_many(names : Array(String), scan_bytes : UInt64 = DEFAULT_SCAN_BYTES) : Array(FetchResult)
      names.map do |name|
        result = fetch_matches_with_status(name, scan_bytes)
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
      record = output.to_s
      newline = record.index('\n')
      header = newline ? record[0, newline + 1] : record
      raise Error.new("index/input mismatch: empty FASTQ record at #{candidate.record_offset}") if header.empty?
      actual = Fastq.name_from_header(header)
      expected = @index.normalize_query(query)
      actual == expected ? record : nil
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
