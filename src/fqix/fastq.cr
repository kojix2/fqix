require "./error"

module Fqix
  module Fastq
    extend self

    # Streaming parser for four-line FASTQ records.
    class StreamParser
      NEWLINE = '\n'.ord.to_u8

      def initialize(@on_line : Proc(Bytes, Int32, UInt64, Nil),
                     @on_record : Proc(UInt64, Bool))
        @offset = 0_u64
        @line_start = 0_u64
        @record_start = 0_u64
        @line_in_record = 0
        @pending = false
      end

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

      def finish(strict : Bool = true) : Bool
        return false if @pending && !finalize_line
        raise Error.new("truncated FASTQ record at end of stream") if strict && @line_in_record != 0
        true
      end

      private def capture(segment : Bytes) : Nil
        @record_start = @line_start if @line_in_record == 0
        @on_line.call(segment, @line_in_record, @line_start)
        @offset += segment.size
      end

      private def finalize_line : Bool
        @pending = false
        @line_in_record += 1
        @line_start = @offset
        return true unless @line_in_record == 4

        @line_in_record = 0
        @on_record.call(@record_start)
      end
    end

    def name_from_header(header : String) : String
      unless header.starts_with?('@')
        raise Error.new("invalid FASTQ header: #{header.inspect}")
      end
      name = header[1..]
      index = first_whitespace_index(name)
      index ? name[0, index] : name
    end

    private def first_whitespace_index(s : String) : Int32?
      s.each_char_with_index do |char, index|
        return index if char.whitespace?
      end
      nil
    end
  end
end
