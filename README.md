# Let's Retire `Sequence` and `IteratorProtocol`

tldr: `Sequence` and `IteratorProtocol` are not pulling their weight,
so we should remove them from the language.


## Costs of `Sequence`

- Shadowing
- Semantic difficulty with mutation
- `SubSequence` but no slicing
- API surface

## Why do we have `Sequence` and `IteratorProtocol`?

These protocols were originally created to support `for` looping over
arbitrary sequences.  The code 

```swift
for x in seq { something(x) }
```

would be compiled as:

```swift
__i = seq.makeIterator()
while let x = __i.next() { something(x) }
```

where `seq` could have any type conforming to `Sequence`.  It was an
extremely simple model that directly addressed the needs of the `for`
loop and could support trivial generic algorithms such as `reduce`,
`map`, and `filter` besides.

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

## But Sequences Can be Infinite

Currently `Collection` models are required to have a finite number of
elements, but a `Sequence` that is not a `Collection` can be inifinte.
This requirement is motivated as follows in the documentation:

> The fact that all collections are finite guarantees the safety of
> many sequence operations, such as using the `contains(_:)` method to
> test whether a collection includes an element.

It should be noted first off that the comment is misleading at best:
finiteness does not make any difference to memory safety, which is
what “safe” means in Swift.  The only possible consequence of allowing
infinite collections is that some algorithms might run forever or
exhaust memory, neither of which is a safety problem.

More importantly, though, the motivation is hollow: 

- When it comes to termination or memory exhaustion, there's little
  practical difference between an infinite collection and one that is
  simply huge.  We don't have a problem with `0...UInt64.max` as a
  collection, and yet no reasonable program can process all of its
  elements.
  
- The standard library provides *many* `Sequence` algorithms that may
  never terminate when the target is inifinite: among them,
  We provide `min()`/`max()`, `starts(with:)`, `elementsEqual()`.

Since it would do no harm to allow infinite collections, support for
infinite sequences is not legitimate a motivation for the existence of
the `Sequence` protocol.

## Some Sequences are Fundamentally Single-Pass

While it's easy to build a sequence that is single-pass, sequences
that are *fundamentally* single-pass are extremely rare.  For example,
the following is only single-pass because of a design choice:

```swift
// Would be multipass if declared as a struct
class Seq : Sequence, IteratorProtocol {
    var i = 0
    func makeIterator() -> Seq { return self }
    func next() -> Int? { return i >= 10 ? nil : (i, i+=1).0 }
}
let s = Seq()
print(Array(s)) // [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
print(Array(s)) // [] oops, s was mutated
```

A sequence that is *fundamentally* single-pass would require
significant storage or computation to support multiple passes over its
elements.  There are two known cases:

1. The initial state of the element generation procedure, which is
   modified as new elements are generated, is very costly to construct
   and to store, such as in the [Mersenne
   Twister](https://en.wikipedia.org/wiki/Mersenne_Twister)
   pseudo-random number generator.
   
2. The sequence represents some volatile, non-reproducible data
   stream, such as readings from a temperature sensor, or a hardware
   random number generator.
   
## Why Single-Pass Sequences Don't Need a Protocol

Semantically, any single-pass sequence of `T`s can be captured in a
**generator** function of the form `()->T?`.  Generators avoid the
impression given by `Sequence` that it can be traversed without
mutation and by `IteratorProtocol` that it can be independently copied
and stored.  If the need should arise to build generic systems over
single-pass sequences, generators would make a fine basis.  Any
`Collection` could interoperate with such a system using this
extension:

```swift
extension Collection {
    /// Returns a generator for the elements of `self`.
    var makeStream() -> ()->Element? {
        var state = self[...]
        return { state.popFirst() }
    }
}
```

The more interesting question, since I'm proposing to eliminate
`Sequence`, is how a fundamentally single-pass sequence could be made
to interoperate with an algorithm that requires `Collection`.  We can
add multipass capability using an adapter that buffers blocks of
elements as they are visited for the first time. The accompanying
[GeneratorCollection.swift](GeneratorCollection.swift) is an example.

Needlessly buffering an entire stream would be unacceptable, but
traversing a `GeneratorCollection` just once can be much cheaper than
that, as the example demonstrates: just one block buffer is allocated
and reused throughout the traversal.  This overhead of this block
buffer is real, but I argue that in the already-rare places it would
be needed, it will usually not be significant: truly single-pass
streams already pay substantial performance costs for their large
state, I/O, or both.  In the rare instances where this cost is
unacceptable, algorithms can be refactored and overloaded to use
generators.  Array initialization is one likely candidate.
