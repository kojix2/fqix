# zran-style random access support for gzip streams.
#
# This file implements zran-derived checkpointing and extraction for fqix.
# The overall fqix project is licensed under the MIT License, but this
# zran-related implementation is distributed under the zlib License.
#
# The design is based on Mark Adler's zran example from zlib:
#
#   Copyright (C) 2005, 2012, 2018, 2023, 2024, 2025 Mark Adler
#   For conditions of distribution and use, see the zlib license.
#
# fqix-specific Crystal implementation:
#
#   Copyright (c) 2026 Kojix2
#
require "lib_z"
require "./binary_io"
require "./error"

@[Link("z")]
lib LibZ
  fun inflatePrime(stream : ZStream*, bits : Int32, value : Int32) : Error
  fun inflateReset2(stream : ZStream*, window_bits : Int32) : Error
end

module Fqix
  module Zran
    CHUNK_SIZE       = 65_536
    WINDOW_SIZE      = 32_768
    GZIP_WINDOW_BITS =     47
    RAW_WINDOW_BITS  =    -15
    TMP_MAGIC        = "FQIXZR1\0"

    struct Checkpoint
      getter out_offset : UInt64
      getter in_offset : UInt64
      getter bits : UInt8
      getter have : UInt32
      getter window : Bytes

      def initialize(@out_offset : UInt64, @in_offset : UInt64, @bits : UInt8, @have : UInt32, @window : Bytes)
      end
    end

    record ExtractResult, path : String, limit_reached : Bool

    def self.build_to_temp(gz_path : String, span : UInt64, consumer : Proc(Bytes, Nil)? = nil) : String
      raise Error.new("checkpoint span must be greater than zero") if span == 0
      tmp = File.tempname("fqix-zran", ".tmp")

      begin
        File.open(gz_path, "rb") do |input|
          File.open(tmp, "wb+") do |output|
            build_temp_index(input, output, span, consumer)
          end
        end
      rescue ex
        File.delete(tmp) if File.exists?(tmp)
        raise Error.new(ex.message || "zran build failed")
      end

      tmp
    end

    def self.read_temp(path : String) : Array(Checkpoint)
      File.open(path, "rb") do |io|
        magic = Bytes.new(8)
        io.read_fully(magic)
        unless String.new(magic) == TMP_MAGIC
          raise Error.new("invalid temporary zran file")
        end
        count = BinaryIO.read_u64(io)
        cps = Array(Checkpoint).new(count.to_i)
        count.times do
          out_offset = BinaryIO.read_u64(io)
          in_offset = BinaryIO.read_u64(io)
          bits = BinaryIO.read_u8(io)
          have = BinaryIO.read_u32(io)
          window = Bytes.new(WINDOW_SIZE)
          io.read_fully(window)
          cps << Checkpoint.new(out_offset, in_offset, bits, have, window)
        end
        cps
      end
    end

    def self.extract_to_temp(gz_path : String, checkpoint : Checkpoint, skip : UInt64, max_out : UInt64) : String
      extract_to_temp_result(gz_path, checkpoint, skip, max_out).path
    end

    def self.extract_to_temp_result(gz_path : String, checkpoint : Checkpoint, skip : UInt64, max_out : UInt64) : ExtractResult
      tmp = File.tempname("fqix-extract", ".fastq")
      limit_reached = false

      begin
        File.open(tmp, "wb") do |output|
          sink = ->(chunk : Bytes) { output.write(chunk); true }
          limit_reached = run_extract(gz_path, checkpoint, skip, max_out, sink)
        end
      rescue ex
        File.delete(tmp) if File.exists?(tmp)
        raise Error.new(ex.message || "zran extract failed")
      end

      ExtractResult.new(tmp, limit_reached)
    end

    # Streaming extraction without a temporary file: decompressed bytes (after
    # `skip`) are pushed to `sink` in chunks. `sink` returns false to stop
    # extraction early (e.g. once the wanted record has been found). Returns
    # true if extraction stopped because `max_out` was reached, rather than
    # end-of-stream or an early stop.
    def self.extract_to(gz_path : String, checkpoint : Checkpoint, skip : UInt64, max_out : UInt64, sink : Proc(Bytes, Bool)) : Bool
      run_extract(gz_path, checkpoint, skip, max_out, sink)
    end

    private def self.run_extract(gz_path : String, checkpoint : Checkpoint, skip : UInt64, max_out : UInt64, sink : Proc(Bytes, Bool)) : Bool
      stream = LibZ::ZStream.new

      File.open(gz_path, "rb") do |input|
        input.seek(checkpoint.in_offset.to_i64, IO::Seek::Set)
        raw = checkpoint.out_offset != 0
        window_bits = raw ? RAW_WINDOW_BITS : GZIP_WINDOW_BITS

        ret = LibZ.inflateInit2(pointerof(stream), window_bits, LibZ.zlibVersion, sizeof(LibZ::ZStream))
        raise_zlib_error("inflateInit2 failed during extract", ret)

        begin
          prime_raw_checkpoint(input, pointerof(stream), checkpoint) if raw
          return extract_stream(input, pointerof(stream), skip, max_out, raw, sink)
        ensure
          LibZ.inflateEnd(pointerof(stream))
        end
      end

      false
    rescue ex : Error
      raise ex
    rescue ex
      raise Error.new(ex.message || "zran extract failed")
    end

    private def self.prime_raw_checkpoint(input : File, stream : LibZ::ZStream*, checkpoint : Checkpoint)
      if checkpoint.have > 0
        ret = LibZ.inflateSetDictionary(stream, checkpoint.window.to_unsafe, checkpoint.have)
        raise_zlib_error("inflateSetDictionary failed", ret)
      end

      return if checkpoint.bits == 0

      byte = input.read_byte
      raise Error.new("unexpected EOF while priming bits") unless byte
      value = byte.to_i >> (8 - checkpoint.bits)
      ret = LibZ.inflatePrime(stream, checkpoint.bits, value)
      raise_zlib_error("inflatePrime failed", ret)
    end

    private def self.extract_stream(input : File,
                                    stream : LibZ::ZStream*,
                                    skip : UInt64,
                                    max_out : UInt64,
                                    raw : Bool,
                                    sink : Proc(Bytes, Bool)) : Bool
      input_buffer = Bytes.new(CHUNK_SIZE)
      output_buffer = Bytes.new(CHUNK_SIZE)
      written = 0_u64
      skipped = 0_u64

      stream.value.avail_in = 0_u32
      while written < max_out
        read_input(input, stream, input_buffer)
        break if stream.value.avail_in == 0

        stream.value.next_out = output_buffer.to_unsafe
        stream.value.avail_out = output_buffer.size.to_u32
        ret = LibZ.inflate(stream, LibZ::Flush::NO_FLUSH)
        unless ret.ok? || ret.stream_end?
          raise_zlib_error("inflate failed during extract", ret)
        end

        produced = output_buffer.size - stream.value.avail_out
        return false unless write_extracted_chunk(output_buffer[0, produced], skip, pointerof(skipped), max_out, pointerof(written), sink)

        next if !ret.stream_end?

        break unless prepare_next_member_for_extract(input, stream, input_buffer, raw)
        raw = false
      end
      written >= max_out
    end

    private def self.write_extracted_chunk(chunk : Bytes,
                                           skip : UInt64,
                                           skipped : UInt64*,
                                           max_out : UInt64,
                                           written : UInt64*,
                                           sink : Proc(Bytes, Bool)) : Bool
      pos = bytes_to_drop(chunk.size, skip, skipped)
      return true if pos >= chunk.size

      available = chunk.size - pos
      want = max_out - written.value
      size = want < available ? want.to_i : available
      return true if size <= 0

      return false unless sink.call(chunk[pos, size])
      written.value += size
      true
    end

    private def self.bytes_to_drop(size : Int32, skip : UInt64, skipped : UInt64*) : Int32
      return 0 unless skipped.value < skip

      need = skip - skipped.value
      drop = need < size ? need.to_i : size
      skipped.value += drop
      drop
    end

    private def self.build_temp_index(input : File, output : File, checkpoint_span : UInt64, consumer : Proc(Bytes, Nil)?)
      stream = LibZ::ZStream.new

      write_temp_header(output)
      write_checkpoint(output, 0_u64, 0_u64, 0_u8, Bytes.empty)

      ret = LibZ.inflateInit2(pointerof(stream), GZIP_WINDOW_BITS, LibZ.zlibVersion, sizeof(LibZ::ZStream))
      raise_zlib_error("inflateInit2 failed", ret)

      begin
        count = process_index_stream(input, output, pointerof(stream), checkpoint_span, consumer)
        write_count_at(output, count)
      ensure
        LibZ.inflateEnd(pointerof(stream))
      end
    end

    private def self.process_index_stream(input : File, output : File, stream : LibZ::ZStream*, checkpoint_span : UInt64, consumer : Proc(Bytes, Nil)?) : UInt64
      count = 1_u64
      out_seen = 0_u64
      member_start = 0_u64
      last_point = 0_u64
      window = Bytes.new(WINDOW_SIZE)
      input_buffer = Bytes.new(CHUNK_SIZE)
      output_buffer = Bytes.new(CHUNK_SIZE)
      input_read = 0_u64

      stream.value.avail_in = 0_u32
      loop do
        read_input(input, stream, input_buffer, pointerof(input_read))
        ret = inflate_blocks(
          output,
          stream,
          output_buffer,
          window,
          pointerof(out_seen),
          pointerof(member_start),
          pointerof(last_point),
          pointerof(count),
          checkpoint_span,
          input_read,
          consumer
        )
        if ret.stream_end? && reset_for_next_member(input, stream, input_buffer, pointerof(input_read), pointerof(member_start), out_seen)
          next
        end
        break if ret.stream_end?
      end

      count
    end

    private def self.read_input(input : File, stream : LibZ::ZStream*, buffer : Bytes, input_read : UInt64*? = nil)
      return unless stream.value.avail_in == 0

      stream.value.next_in = buffer.to_unsafe
      bytes_read = input.read(buffer)
      input_read.value += bytes_read if input_read
      stream.value.avail_in = bytes_read.to_u32
    end

    private def self.inflate_blocks(output : File,
                                    stream : LibZ::ZStream*,
                                    buffer : Bytes,
                                    window : Bytes,
                                    out_seen : UInt64*,
                                    member_start : UInt64*,
                                    last_point : UInt64*,
                                    count : UInt64*,
                                    checkpoint_span : UInt64,
                                    input_read : UInt64,
                                    consumer : Proc(Bytes, Nil)?) : LibZ::Error
      loop do
        stream.value.next_out = buffer.to_unsafe
        stream.value.avail_out = buffer.size.to_u32
        ret = LibZ.inflate(stream, LibZ::Flush::BLOCK)

        produced = buffer.size - stream.value.avail_out
        if produced > 0
          chunk = buffer[0, produced]
          append_window(window, out_seen, chunk)
          consumer.try &.call(chunk)
        end
        raise_zlib_error("inflate failed while building zran index", ret) unless ret.ok? || ret.stream_end?

        if checkpoint_ready?(stream.value, out_seen.value, last_point.value, checkpoint_span)
          write_index_checkpoint(output, stream.value, window, out_seen.value, member_start.value, input_read)
          count.value += 1
          last_point.value = out_seen.value
        end

        return ret if stream.value.avail_in == 0 || ret.stream_end?
      end
    end

    private def self.checkpoint_ready?(stream : LibZ::ZStream, out_seen : UInt64, last_point : UInt64, span : UInt64) : Bool
      data_type = stream.data_type
      out_seen - last_point >= span && (data_type & 128) != 0 && (data_type & 64) == 0
    end

    private def self.write_index_checkpoint(output : File,
                                            stream : LibZ::ZStream,
                                            window : Bytes,
                                            out_seen : UInt64,
                                            member_start : UInt64,
                                            input_read : UInt64)
      in_offset = input_read - stream.avail_in
      bits = (stream.data_type & 7).to_u8
      in_offset &-= 1 if bits != 0
      write_checkpoint(output, out_seen, in_offset, bits, make_dict(window, out_seen, member_start))
    end

    private def self.reset_for_next_member(input : File,
                                           stream : LibZ::ZStream*,
                                           buffer : Bytes,
                                           input_read : UInt64*,
                                           member_start : UInt64*,
                                           out_seen : UInt64) : Bool
      next_member_pos = input_read.value - stream.value.avail_in
      input.seek(next_member_pos.to_i64, IO::Seek::Set)
      input_read.value = next_member_pos
      stream.value.avail_in = 0_u32

      return false unless ensure_input_available(input, stream, buffer, input_read)
      ret = LibZ.inflateReset2(stream, GZIP_WINDOW_BITS)
      raise_zlib_error("inflateReset2 failed while building zran index", ret)
      member_start.value = out_seen
      true
    end

    private def self.prepare_next_member_for_extract(input : File, stream : LibZ::ZStream*, buffer : Bytes, raw : Bool) : Bool
      next_member_pos = input.pos.to_u64 - stream.value.avail_in
      next_member_pos += 8 if raw

      input.seek(next_member_pos.to_i64, IO::Seek::Set)
      stream.value.avail_in = 0_u32
      return false unless ensure_input_available(input, stream, buffer)

      ret = LibZ.inflateReset2(stream, GZIP_WINDOW_BITS)
      raise_zlib_error("inflateReset2 failed during extract", ret)
      true
    end

    private def self.ensure_input_available(input : File, stream : LibZ::ZStream*, buffer : Bytes, input_read : UInt64*? = nil) : Bool
      return true if stream.value.avail_in > 0

      stream.value.next_in = buffer.to_unsafe
      bytes_read = input.read(buffer)
      input_read.value += bytes_read if input_read
      stream.value.avail_in = bytes_read.to_u32
      bytes_read > 0
    end

    private def self.append_window(window : Bytes, out_seen : UInt64*, bytes : Bytes)
      pos = out_seen.value
      n = bytes.size
      out_seen.value = pos + n

      # Only the last WINDOW_SIZE bytes can ever survive in the circular buffer,
      # so copy at most that many. WINDOW_SIZE is a power of two, so the slice of
      # source bytes maps onto the window in at most two contiguous runs.
      keep = n < WINDOW_SIZE ? n : WINDOW_SIZE
      src_off = n - keep
      dst = ((pos + src_off) & (WINDOW_SIZE - 1).to_u64).to_i
      head = WINDOW_SIZE - dst
      head = keep if keep < head

      window[dst, head].copy_from(bytes[src_off, head])
      if keep > head
        window[0, keep - head].copy_from(bytes[src_off + head, keep - head])
      end
    end

    private def self.make_dict(window : Bytes, out_seen : UInt64, member_start : UInt64) : Bytes
      member_bytes = out_seen - member_start
      have = member_bytes < WINDOW_SIZE ? member_bytes.to_i : WINDOW_SIZE
      dict = Bytes.new(have)
      start = out_seen - have
      mask = (WINDOW_SIZE - 1).to_u64
      have.times do |index|
        dict[index] = window[((start + index) & mask).to_i]
      end
      dict
    end

    private def self.write_temp_header(io : IO)
      io.write(TMP_MAGIC.to_slice)
      BinaryIO.write_u64(io, 0_u64)
    end

    private def self.write_count_at(io : File, count : UInt64)
      io.seek(8, IO::Seek::Set)
      BinaryIO.write_u64(io, count)
      io.seek(0, IO::Seek::End)
    end

    private def self.write_checkpoint(io : IO, out_offset : UInt64, in_offset : UInt64, bits : UInt8, dict : Bytes)
      have = dict.size > WINDOW_SIZE ? WINDOW_SIZE : dict.size
      BinaryIO.write_u64(io, out_offset)
      BinaryIO.write_u64(io, in_offset)
      BinaryIO.write_u8(io, bits)
      BinaryIO.write_u32(io, have.to_u32)
      io.write(dict[0, have]) if have > 0
      io.write(Bytes.new(WINDOW_SIZE - have)) if have < WINDOW_SIZE
    end

    private def self.raise_zlib_error(message : String, ret : LibZ::Error)
      return if ret.ok?
      detail = String.new(LibZ.zError(ret))
      raise Error.new("#{message}: #{detail}")
    end
  end
end
