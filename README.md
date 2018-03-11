# Let's Retire `Sequence` and `IteratorProtocol`

`Sequence` and `IteratorProtocol` are not pulling their weight, so we
should remove them from the language.

## Why do we have `Sequence` and `IteratorProtocol`?

Historically, these protocols were created to support the `for`...`in`
loop over arbitrary lists of elements.  The compiler was made to
recognize an instance any type conforming to `Sequence` as eligible
for use in a loop.  It was an extremely simple model that directly
addressed the needs of that one language construct.

- Single Pass
- Infinite

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
  
