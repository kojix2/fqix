module Fqix
  module BinaryIO
    extend self

    def read_u8(io : IO) : UInt8
      io.read_byte || raise IO::EOFError.new
    end

    def read_u16(io : IO) : UInt16
      value = 0_u16
      2.times { |i| value |= read_u8(io).to_u16 << (8 * i) }
      value
    end

    def read_u32(io : IO) : UInt32
      value = 0_u32
      4.times { |i| value |= read_u8(io).to_u32 << (8 * i) }
      value
    end

    def read_u64(io : IO) : UInt64
      value = 0_u64
      8.times { |i| value |= read_u8(io).to_u64 << (8 * i) }
      value
    end

    def read_i64(io : IO) : Int64
      read_u64(io).to_i64!
    end

    def write_u8(io : IO, value : UInt8)
      io.write_byte(value)
    end

    def write_u16(io : IO, value : UInt16)
      2.times { |i| io.write_byte(((value >> (8 * i)) & 0xff).to_u8) }
    end

    def write_u32(io : IO, value : UInt32)
      4.times { |i| io.write_byte(((value >> (8 * i)) & 0xff).to_u8) }
    end

    def write_u64(io : IO, value : UInt64)
      8.times { |i| io.write_byte(((value >> (8 * i)) & 0xff).to_u8) }
    end

    def write_i64(io : IO, value : Int64)
      write_u64(io, value.to_u64!)
    end
  end
end
