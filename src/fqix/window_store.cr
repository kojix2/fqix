require "./error"
require "./zran"
require "compress/deflate"

module Fqix
  record CompressedWindowDescriptor, rel_offset : UInt64, compressed_size : UInt32, have : UInt32

  abstract class WindowStore
    abstract def get(id : Int) : Bytes
  end

  class MemoryWindowStore < WindowStore
    def initialize(@windows : Array(Bytes))
    end

    def get(id : Int) : Bytes
      @windows[id]
    end
  end

  class FileWindowStore < WindowStore
    def initialize(@path : String, @windows_offset : UInt64)
      @cached_checkpoint_id = nil.as(Int32?)
      @cached_window = nil.as(Bytes?)
    end

    def get(id : Int) : Bytes
      id = id.to_i
      if @cached_checkpoint_id == id
        if window = @cached_window
          return window
        end
      end

      window = Bytes.new(Zran::WINDOW_SIZE)
      File.open(@path, "rb") do |io|
        offset = @windows_offset + id.to_u64 * Zran::WINDOW_SIZE.to_u64
        io.seek(offset.to_i64, IO::Seek::Set)
        io.read_fully(window)
      end

      @cached_checkpoint_id = id
      @cached_window = window
      window
    end
  end

  class CompressedFileWindowStore < WindowStore
    def initialize(@path : String, @windows_offset : UInt64, @descriptors : Array(CompressedWindowDescriptor))
      @cached_checkpoint_id = nil.as(Int32?)
      @cached_window = nil.as(Bytes?)
    end

    def get(id : Int) : Bytes
      id = id.to_i
      if @cached_checkpoint_id == id
        if window = @cached_window
          return window
        end
      end

      descriptor = @descriptors[id]
      window =
        if descriptor.have == 0
          Bytes.empty
        else
          inflate_window(descriptor)
        end

      @cached_checkpoint_id = id
      @cached_window = window
      window
    end

    private def inflate_window(descriptor : CompressedWindowDescriptor) : Bytes
      compressed = Bytes.new(descriptor.compressed_size)
      File.open(@path, "rb") do |io|
        io.seek((@windows_offset + descriptor.rel_offset).to_i64, IO::Seek::Set)
        io.read_fully(compressed)
      end

      output = Bytes.new(descriptor.have)
      reader = Compress::Deflate::Reader.new(IO::Memory.new(compressed))
      begin
        reader.read_fully(output)
        unless reader.read(Bytes.new(1)) == 0
          raise Error.new("invalid fqix compressed checkpoint window")
        end
      rescue ex : IO::EOFError
        raise Error.new("invalid fqix compressed checkpoint window", cause: ex)
      rescue ex : Compress::Deflate::Error
        raise Error.new("invalid fqix compressed checkpoint window", cause: ex)
      ensure
        reader.close
      end
      output
    end
  end
end
