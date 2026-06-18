require "./error"
require "./zran"

module Fqix
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
end
