require "./error"

module Fqix
  module Fastq
    extend self

    def read_name(header : String) : String
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
