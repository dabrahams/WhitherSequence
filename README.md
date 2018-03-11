# Let's Retire `Sequence` and `IteratorProtocol`

tldr: `Sequence` and `IteratorProtocol` are not pulling their weight, so we
should remove them from the language.

## Why do we have `Sequence` and `IteratorProtocol`?

Historically, these protocols were created to support the `for`...`in`
loop over an arbitrary sequence (small ‘s’) of elements.  The compiler
was made to recognize an instance any type conforming to `Sequence` as
eligible for use in a loop.  It was an extremely simple model that
directly addressed the needs of that one language construct, and could
support trivial generic algorithms such as `reduce`, `map`, and
`filter`.

The `Sequence` model was, however, *too* simple to support nontrivial
algorithms such as reverse, sort, and binary search.  The nontrivial
algorithms had a common need to represent, and revisit, a
*position*—or *index*—in the sequence.

When we discover that an already-useful protocol lacks the
requirements needed to support an important usage, we have to decide
where to add those requirements: to the original protocol, or to a new
*refinement* of the original protocol.  To make that decision, we ask
whether any known models of the protocol would be unable to
efficiently support the new requirement.  This is, for example, why
`BidirectionalCollection` and `RandomAccessCollection` are distinct
protocols: random access is an important capability for some
algorithms, but there is no efficient way for important collections
such as `Dictionary` and `String` to support it.

We knew from our experience with C++'s *input iterator* concept that
some real-world sequences only support making a single pass over the
elements (a stream of network events is a good example). The same
experience told us that representing anything like a “position” in
such a stream was fraught with design problems.  Based on these
factors, combined with the high (at the time) engineering cost
associated with changing the way the compiler implemented `for`...`in`
to interact with a more complicated protocol such as `Collection`, we
decided that single-pass sequences deserved their own protocol…
*without ever discovering a model that couldn't efficiently support
multi-pass operation*.

## Problems caused by `Sequence`

- Shadowing
- Semantic difficulty with mutation
- `SubSequence` but no slicing
- API surface

## We Don't Need Protocols for Single-Pass Behavior

- Actual single-pass behavior is rare

- Interoperability of any actual single-pass sequence with
  `Collection` algorithms can be efficient using a
  `GeneratorCollection` adapter.
  
- Most volatile data streams end up being backed by buffers, in
  practice.
  
- Most volatile data streams are tied to I/O and so already incur
  overheads that would dwarf the cost of allocating a backing buffer.

- A generator of the form `()->T?` works just fine if we ever need to
  describe a single-pass sequence of `T`.  Probably Array should
  support construction from a generator.

## It's Fine to Allow Collections to be Infinite

- The worst consequence is infinite looping/out-of-memory, neither of
  which opens a type-safety hole.
  
- We currently don't do anything to prevent that with Sequence.
  We provide `min()`/`max()`, `starts(with:)`, `elementsEqual()`,
  and many others that can produce these behaviors.
  
- There's little practical difference between an infinite collection
  and one that is simply huge.  We don't have a problem with
  `0...UInt64.max` as a collection.
  
