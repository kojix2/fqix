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

    record FetchResult, status : FetchStatus, record : String? do
      def self.found(record : String) : FetchResult
        new(FetchStatus::Found, record)
      end

      def self.not_found : FetchResult
        new(FetchStatus::NotFound, nil)
      end

      def self.scan_limit_reached : FetchResult
        new(FetchStatus::ScanLimitReached, nil)
      end
    end

    def initialize(@gz_path : String, @index : Index)
    end

    def fetch(name : String, scan_bytes : UInt64 = DEFAULT_SCAN_BYTES) : String?
      result = fetch_with_status(name, scan_bytes)
      result.status.found? ? result.record : nil
    end

    def fetch_with_status(name : String, scan_bytes : UInt64 = DEFAULT_SCAN_BYTES) : FetchResult
      fetch_many([name], scan_bytes).first
    end

    def fetch_many(names : Array(String), scan_bytes : UInt64 = DEFAULT_SCAN_BYTES) : Array(FetchResult)
      results = Array(FetchResult).new(names.size, FetchResult.not_found)
      groups = Hash(Tuple(UInt64, UInt64), Array(Tuple(Int32, String))).new do |hash, key|
        hash[key] = [] of Tuple(Int32, String)
      end

      names.each_with_index do |name, index|
        next unless entry = @index.find_floor_name(name)

        groups[{entry.checkpoint_id, entry.delta}] << {index, name}
      end

      groups.each do |(checkpoint_id, delta), requests|
        cp = @index.checkpoint(checkpoint_id.to_i)
        scanner = BatchRecordScanner.new(requests, results)
        limit_reached = Zran.extract_to(@gz_path, cp, delta, scan_bytes, ->(chunk : Bytes) { scanner.feed(chunk) })
        scanner.finish
        scanner.mark_unresolved(limit_reached)
      end

      results
    end

    # Streaming, four-line FASTQ matcher for one or more query names. Fed
    # decompressed chunks during extraction, it stops once every query in its
    # group is found or ordered-past.
    private class BatchRecordScanner
      def initialize(requests : Array(Tuple(Int32, String)), @results : Array(FetchResult))
        @targets = Hash(String, Array(Int32)).new do |hash, key|
          hash[key] = [] of Int32
        end
        requests.each do |index, name|
          @targets[name] << index
        end

        @pending = @targets.keys
        @buf = IO::Memory.new    # full bytes of the record being assembled
        @header = IO::Memory.new # bytes of the current header line only
        @framer = Fastq::StreamParser.new(
          ->(segment : Bytes, line_in_record : Int32, _line_start : UInt64) {
            @buf.write(segment)
            @header.write(segment) if line_in_record == 0
          },
          ->(_record_start : UInt64) {
            decide
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

      def mark_unresolved(limit_reached : Bool) : Nil
        status = limit_reached ? FetchResult.scan_limit_reached : FetchResult.not_found
        @pending.each do |name|
          @targets[name].each do |index|
            @results[index] = status
          end
        end
        @pending.clear
      end

      private def decide : Nil
        name = Fastq.name_from_header(@header.to_s)
        record = nil.as(String?)
        next_pending = [] of String

        @pending.each do |query|
          order = Order.compare(name, query)
          if order == 0 && name == query
            found_record = record || @buf.to_s
            record = found_record
            @targets[query].each do |index|
              @results[index] = FetchResult.found(found_record)
            end
          elsif order > 0
            @targets[query].each do |index|
              @results[index] = FetchResult.not_found
            end
          else
            next_pending << query
          end
        end

        @pending = next_pending
        @buf.clear
        @header.clear
      end

      private def done? : Bool
        @pending.empty?
      end
    end
  end
end
