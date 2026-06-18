require "./fastq"
require "./index"
require "./zran"

module Fqix
  class Reader
    enum FetchStatus
      Found
      NotFound
    end

    record FetchResult, status : FetchStatus, record : String? do
      def self.found(record : String) : FetchResult
        new(FetchStatus::Found, record)
      end

      def self.not_found : FetchResult
        new(FetchStatus::NotFound, nil)
      end
    end

    def initialize(@gz_path : String, @index : Index)
    end

    def fetch(name : String) : String?
      result = fetch_with_status(name)
      result.status.found? ? result.record : nil
    end

    def fetch_with_status(name : String) : FetchResult
      fetch_many([name]).first
    end

    def fetch_all(name : String) : Array(String)
      fetch_matches(name).map(&.[1])
    end

    def fetch_matches(name : String) : Array(Tuple(UInt64, String))
      @index.find_entries(name).map { |entry| {entry.record_number, fetch_entry(name, entry)} }
    end

    def fetch_many(names : Array(String)) : Array(FetchResult)
      names.map do |name|
        entries = @index.find_entries(name)
        if entry = entries.first?
          FetchResult.found(fetch_entry(name, entry))
        else
          FetchResult.not_found
        end
      end
    end

    private def fetch_entry(query : String, entry : Entry) : String
      checkpoint_id = Index.checkpoint_for(@index.checkpoint_metas, entry.record_offset)
      checkpoint = @index.checkpoint(checkpoint_id)
      delta = entry.record_offset - @index.checkpoint_metas[checkpoint_id].out_offset
      output = IO::Memory.new
      Zran.extract_to(@gz_path, checkpoint, delta, entry.record_size, ->(chunk : Bytes) {
        output.write(chunk)
        true
      })
      record = output.to_s
      newline = record.index('\n')
      header = newline ? record[0, newline + 1] : record
      raise Error.new("index/input mismatch: empty FASTQ record at #{entry.record_offset}") if header.empty?
      actual = Fastq.name_from_header(header)
      expected = @index.normalize_query(query)
      unless actual == expected
        raise Error.new("index/input mismatch for #{expected}: found #{actual} at indexed offset")
      end
      record
    end
  end
end
