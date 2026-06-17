module Fqix
  # Read-name ordering for the index.
  #
  # The entire index is driven by this single comparator: the build-time sort
  # check, the sparse-anchor binary search, and the forward scan during lookup
  # all defer to `compare`. As long as the FASTQ is sorted by the same order
  # this function defines, lookups are correct — the order need not be bytewise
  # lexicographic.
  #
  # To support a different ordering (natural/numeric order, a coordinate key,
  # `samtools sort -n` order, ...), replace the body of `compare` and rebuild;
  # build and lookup stay consistent automatically because they share this one
  # definition. Only a pairwise comparison is required — no global key.
  #
  # `compare(a, b)` must be a transitive order returning a negative, zero, or
  # positive Int32 when `a` orders before, the same as, or after `b`. It may be
  # a weak order (distinct names comparing equal); the lookup path still matches
  # the exact requested name within an equal-ordered run.
  module Order
    extend self

    def compare(a : String, b : String) : Int32
      a <=> b
    end
  end
end
