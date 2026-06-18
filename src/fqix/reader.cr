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
      entry = @index.find_floor_name(name)
      return FetchResult.not_found unless entry

      cp = @index.checkpoint(entry.checkpoint_id.to_i)
      scanner = RecordScanner.new(name)
      # Decompress straight into the scanner; it stops the inflate loop as soon
      # as the record is found or passed, so no temporary file is written and we
      # rarely inflate the full scan window.
      limit_reached = Zran.extract_to(@gz_path, cp, entry.delta, scan_bytes, ->(chunk : Bytes) { scanner.feed(chunk) })
      scanner.finish

      if record = scanner.record
        FetchResult.found(record)
      elsif scanner.passed?
        FetchResult.not_found
      else
        limit_reached ? FetchResult.scan_limit_reached : FetchResult.not_found
      end
    end

    # Streaming, four-line FASTQ record matcher. Fed decompressed chunks during
    # extraction, it assembles records across chunk boundaries and signals the
    # extractor to stop once the query name is found or passed (records are
    # sorted by name). Only the matching record's bytes are materialized.
    private class RecordScanner
      NEWLINE = '\n'.ord.to_u8

      getter? passed = false
      getter record : String? = nil

      def initialize(@query : String)
        @buf = IO::Memory.new    # full bytes of the record being assembled
        @header = IO::Memory.new # bytes of the current header line only
        @line_in_record = 0
        @pending = false # bytes buffered for an unterminated line
      end

      # Returns false once a decision is reached, to stop extraction early.
      def feed(chunk : Bytes) : Bool
        i = 0
        size = chunk.size
        while i < size
          if nl = chunk.index(NEWLINE, i)
            stop = nl + 1
            capture(chunk[i, stop - i])
            i = stop
            return false unless finalize_line
          else
            capture(chunk[i, size - i])
            @pending = true
            i = size
          end
        end
        true
      end

      # Flush a final line that ended the stream without a trailing newline.
      def finish : Nil
        finalize_line if @pending && record.nil? && !passed?
      end

      private def capture(seg : Bytes) : Nil
        @buf.write(seg)
        @header.write(seg) if @line_in_record == 0
      end

      # Returns false when a decision (found/passed) is reached.
      private def finalize_line : Bool
        @pending = false
        @line_in_record += 1
        return true unless @line_in_record == 4

        @line_in_record = 0
        decide
        record.nil? && !passed?
      end

      private def decide : Nil
        name = Fastq.read_name(@header.to_s)
        order = Order.compare(name, @query)
        if order == 0 && name == @query
          @record = @buf.to_s # exact match within the equal-ordered run
        elsif order > 0
          @passed = true # ordered past the query; it cannot appear later
        else
          # ordered before the query, or equal-ordered but a different name:
          # keep scanning.
          @buf.clear
          @header.clear
        end
      end
    end
  end
end
