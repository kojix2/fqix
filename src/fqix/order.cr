module Fqix
  enum OrderMode : UInt8
    Lexicographic = 1
    Natural       = 2
  end

  # Read-name ordering for the index.
  module Order
    extend self

    def compare(a : String, b : String, mode : OrderMode = OrderMode::Lexicographic) : Int32
      case mode
      in .lexicographic?
        lexicographic_compare(a, b)
      in .natural?
        natural_compare(a, b)
      end
    end

    def lexicographic_compare(a : String, b : String) : Int32
      a <=> b
    end

    def natural_compare(a : String, b : String) : Int32
      a_bytes = a.to_slice
      b_bytes = b.to_slice
      a_pos = 0
      b_pos = 0

      while a_pos < a_bytes.size && b_pos < b_bytes.size
        a_digit = digit?(a_bytes[a_pos])
        b_digit = digit?(b_bytes[b_pos])

        if a_digit && b_digit
          cmp, a_pos, b_pos = compare_digit_runs(a_bytes, a_pos, b_bytes, b_pos)
          return cmp unless cmp == 0
        elsif a_digit != b_digit
          return a_digit ? -1 : 1
        else
          cmp, a_pos, b_pos = compare_non_digit_runs(a_bytes, a_pos, b_bytes, b_pos)
          return cmp unless cmp == 0
        end
      end

      a_bytes.size <=> b_bytes.size
    end

    private def compare_non_digit_runs(a : Bytes, a_pos : Int32, b : Bytes, b_pos : Int32) : Tuple(Int32, Int32, Int32)
      a_end = non_digit_run_end(a, a_pos)
      b_end = non_digit_run_end(b, b_pos)
      cmp = compare_slices(a[a_pos, a_end - a_pos], b[b_pos, b_end - b_pos])
      {cmp, a_end, b_end}
    end

    private def compare_digit_runs(a : Bytes, a_pos : Int32, b : Bytes, b_pos : Int32) : Tuple(Int32, Int32, Int32)
      a_end = digit_run_end(a, a_pos)
      b_end = digit_run_end(b, b_pos)
      a_sig = significant_digit_start(a, a_pos, a_end)
      b_sig = significant_digit_start(b, b_pos, b_end)
      a_sig_len = a_end - a_sig
      b_sig_len = b_end - b_sig

      if cmp = compare_nonzero_digit_lengths(a_sig_len, b_sig_len)
        return {cmp, a_end, b_end}
      end

      cmp = compare_slices(a[a_sig, a_sig_len], b[b_sig, b_sig_len])
      return {cmp, a_end, b_end} unless cmp == 0

      {((a_end - a_pos) <=> (b_end - b_pos)), a_end, b_end}
    end

    private def compare_nonzero_digit_lengths(a_sig_len : Int32, b_sig_len : Int32) : Int32?
      a_zero = a_sig_len == 0
      b_zero = b_sig_len == 0
      return if a_zero && b_zero
      return -1 if a_zero
      return 1 if b_zero

      cmp = a_sig_len <=> b_sig_len
      cmp == 0 ? nil : cmp
    end

    private def digit_run_end(bytes : Bytes, pos : Int32) : Int32
      index = pos
      while index < bytes.size && digit?(bytes[index])
        index += 1
      end
      index
    end

    private def non_digit_run_end(bytes : Bytes, pos : Int32) : Int32
      index = pos
      while index < bytes.size && !digit?(bytes[index])
        index += 1
      end
      index
    end

    private def significant_digit_start(bytes : Bytes, pos : Int32, stop : Int32) : Int32
      index = pos
      while index < stop && bytes[index] == '0'.ord
        index += 1
      end
      index
    end

    private def compare_slices(a : Bytes, b : Bytes) : Int32
      size = Math.min(a.size, b.size)
      index = 0
      while index < size
        cmp = a[index] <=> b[index]
        return cmp unless cmp == 0
        index += 1
      end
      a.size <=> b.size
    end

    private def digit?(byte : UInt8) : Bool
      byte >= '0'.ord && byte <= '9'.ord
    end
  end
end
