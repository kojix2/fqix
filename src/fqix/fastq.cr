require "./error"

module Fqix
  module Fastq
    extend self

    struct Record
      getter header : String
      getter seq : String
      getter plus : String
      getter qual : String

      def initialize(@header : String, @seq : String, @plus : String, @qual : String)
      end

      def name : String
        Fastq.parse_read_name(header)
      end

      def bytesize : UInt64
        header.bytesize.to_u64 + seq.bytesize.to_u64 + plus.bytesize.to_u64 + qual.bytesize.to_u64
      end

      def to_s(io : IO) : Nil
        io << header << seq << plus << qual
      end
    end

    def read_record(io : IO, strict : Bool = true) : Record?
      header = gets_raw(io)
      return unless header

      seq = read_record_line(io, header, strict)
      plus = read_record_line(io, header, strict)
      qual = read_record_line(io, header, strict)
      return unless seq && plus && qual

      Record.new(header, seq, plus, qual)
    end

    def parse_read_name(header : String) : String
      unless header.starts_with?('@')
        raise Error.new("invalid FASTQ header: #{header.inspect}")
      end
      name = header[1..]
      index = first_whitespace_index(name)
      index ? name[0, index] : name
    end

    def gets_raw(io : IO) : String?
      io.gets(chomp: false)
    end

    private def read_record_line(io : IO, header : String, strict : Bool) : String?
      line = gets_raw(io)
      return line if line
      raise Error.new("truncated FASTQ record after #{header}") if strict
    end

    private def first_whitespace_index(s : String) : Int32?
      s.each_char_with_index do |char, index|
        return index if char.whitespace?
      end
      nil
    end
  end
end
