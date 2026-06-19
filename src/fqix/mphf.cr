require "./binary_io"
require "./error"

module Fqix
  # Pure-Crystal BBHash-style minimal perfect hash over distinct UInt64 keys.
  # Non-member lookup is total: it returns nil when absence is provable, or an
  # arbitrary in-range slot when the non-member lands on a placed bit.
  class Mphf
    GAMMA     = 2.0
    MAX_LEVEL =  25
    RANK_STEP = 512

    getter key_count : UInt64

    def initialize(keys : Array(UInt64), @seed : UInt64)
      @bits = [] of Array(UInt64)
      @sizes = [] of UInt64
      @ranks = [] of Array(UInt64)
      @base = [] of UInt64
      @fallback = {} of UInt64 => UInt64
      @key_count = keys.size.to_u64
      build(keys)
    end

    private def initialize(@key_count : UInt64,
                           @seed : UInt64,
                           @bits : Array(Array(UInt64)),
                           @sizes : Array(UInt64),
                           @fallback : Hash(UInt64, UInt64))
      @ranks = [] of Array(UInt64)
      @base = [] of UInt64
      rebuild_rank_index
    end

    def self.empty(seed : UInt64) : Mphf
      new([] of UInt64, seed)
    end

    def self.read(io : IO, bytesize : UInt64, seed : UInt64) : Mphf
      start = io.pos.to_u64
      key_count = BinaryIO.read_u64(io)
      level_count = BinaryIO.read_u32(io)
      fallback_count = BinaryIO.read_u32(io)
      raise Error.new("invalid fqix mphf level count") if level_count > MAX_LEVEL

      sizes = Array(UInt64).new(level_count)
      bits = Array(Array(UInt64)).new(level_count)
      level_count.times do
        size = BinaryIO.read_u64(io)
        word_count = BinaryIO.read_u64(io)
        if word_count > Int32::MAX.to_u64
          raise Error.new("invalid fqix mphf bit count")
        end
        expected_words = (size + 63_u64) // 64_u64
        unless word_count == expected_words
          raise Error.new("invalid fqix mphf bit count")
        end
        words = Array(UInt64).new(word_count.to_i)
        word_count.times { words << BinaryIO.read_u64(io) }
        mask_unused_tail_bits!(words, size)
        sizes << size
        bits << words
      end

      fallback = {} of UInt64 => UInt64
      fallback_count.times do
        key = BinaryIO.read_u64(io)
        value = BinaryIO.read_u64(io)
        fallback[key] = value
      end

      unless io.pos.to_u64 - start == bytesize
        raise Error.new("invalid fqix mphf size")
      end

      mphf = new(key_count, seed, bits, sizes, fallback)
      unless mphf.size == key_count
        raise Error.new("invalid fqix mphf key count")
      end
      mphf
    end

    def write(io : IO) : Nil
      BinaryIO.write_u64(io, @key_count)
      BinaryIO.write_u32(io, @bits.size.to_u32)
      BinaryIO.write_u32(io, @fallback.size.to_u32)
      @bits.each_with_index do |words, index|
        BinaryIO.write_u64(io, @sizes[index])
        BinaryIO.write_u64(io, words.size.to_u64)
        words.each { |word| BinaryIO.write_u64(io, word) }
      end
      @fallback.each do |key, value|
        BinaryIO.write_u64(io, key)
        BinaryIO.write_u64(io, value)
      end
    end

    def to_slice : Bytes
      io = IO::Memory.new
      write(io)
      io.to_slice
    end

    def lookup(key : UInt64) : UInt64?
      @bits.each_with_index do |words, level|
        next if @sizes[level] == 0
        index = level_hash(key, level) % @sizes[level]
        word_index = (index >> 6).to_i
        bit = 1_u64 << (index & 63)
        return @base[level] + rank_within(level, word_index, index) if (words[word_index] & bit) != 0
      end
      @fallback[key]?
    end

    def size : UInt64
      placed = @bits.sum { |words| words.sum(&.popcount) }.to_u64
      placed + @fallback.size.to_u64
    end

    private def build(keys : Array(UInt64)) : Nil
      level_keys = keys
      level = 0
      while !level_keys.empty? && level < MAX_LEVEL
        size = Math.max(1_u64, (GAMMA * level_keys.size).ceil.to_u64)
        words = ((size + 63_u64) // 64_u64).to_i
        placed = Array(UInt64).new(words, 0_u64)
        collided_bits = Array(UInt64).new(words, 0_u64)

        level_keys.each do |key|
          index = level_hash(key, level) % size
          word_index = (index >> 6).to_i
          bit = 1_u64 << (index & 63)
          if (collided_bits[word_index] & bit) != 0
            next
          elsif (placed[word_index] & bit) != 0
            placed[word_index] &= ~bit
            collided_bits[word_index] |= bit
          else
            placed[word_index] |= bit
          end
        end

        collided_keys = level_keys.select do |key|
          index = level_hash(key, level) % size
          (collided_bits[(index >> 6).to_i] & (1_u64 << (index & 63))) != 0
        end

        @bits << placed
        @sizes << size
        level_keys = collided_keys
        level += 1
      end

      next_value = @bits.sum { |level_words| level_words.sum(&.popcount) }.to_u64
      level_keys.each do |key|
        @fallback[key] = next_value
        next_value += 1
      end

      rebuild_rank_index
    end

    private def rebuild_rank_index : Nil
      running = 0_u64
      @bits.each do |words|
        @base << running
        ranks = [] of UInt64
        acc = 0_u64
        words.each_with_index do |word, word_index|
          ranks << acc if (word_index * 64) % RANK_STEP == 0
          acc += word.popcount
        end
        @ranks << ranks
        running += acc
      end
    end

    private def rank_within(level : Int32, word_index : Int32, bit_index : UInt64) : UInt64
      step_words = RANK_STEP // 64
      block = word_index // step_words
      acc = @ranks[level][block]
      words = @bits[level]
      (block * step_words).upto(word_index - 1) { |index| acc += words[index].popcount }
      mask = (1_u64 << (bit_index & 63)) - 1_u64
      acc + (words[word_index] & mask).popcount
    end

    private def level_hash(key : UInt64, level : Int32) : UInt64
      Mphf.mix(key &+ @seed &+ (0x9E3779B97F4A7C15_u64 &* (level.to_u64 &+ 1_u64)))
    end

    def self.mix(value : UInt64) : UInt64
      mixed = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9_u64
      mixed = (mixed ^ (mixed >> 27)) &* 0x94D049BB133111EB_u64
      mixed ^ (mixed >> 31)
    end

    private def self.mask_unused_tail_bits!(words : Array(UInt64), size : UInt64) : Nil
      return if words.empty? || size % 64_u64 == 0

      used = size % 64_u64
      mask = (1_u64 << used) - 1_u64
      words[-1] &= mask
    end
  end
end
