# Let's Repurpose `Sequence`

> TL;DR Evaluated against its documented purpose, `Sequence` is not pulling its
> weight.  It creates pitfalls for library users and complexity for everyone.
> That said, defining a `Sequence` is super easy.  We should make `Sequence` into
> a convenience for defining `Collection`s.

## Costs of `Sequence` In Its Current Form

The biggest problem with `Sequence` is that it is so easily and
regularly misused.  An arbitrary `Sequence` supports only a single
traversal, so any generic code (or extension of Sequence) that
attempts to read the elements multiple times is incorrect.  Reading
the elements includes the use of `for`...`in` loops, but also methods
declared to be non-`mutating`—such as `map`, `filter`, and `reduce`-
that must actually change the value of an arbitrary sequence.  It's
hard to overstate the harm done to code readability, since code that
appears to be pure hides side-effects that occur in the general case.

Because the *vast* majority of `Sequence` models (and all the ones
supplied by the standard library) support multiple passes, generic
code over `Sequence`s is typically never tested with a single-pass
`Sequence`.  Finally, because it is at the root of the protocol
hierarchy and has so few requirements, it is very attractive to
implement `Sequence` where implementing `Collection` would be more
appropriate.  Making a type conform to `Sequence` instead of
`Collection` has both efficiency and capability costs for operations
on that type.

Because the definitions of `Sequence.SubSequence` and `Collection.SubSequence`
conflict, it is currently *impossible* to create a generic type that
conditionally conforms to `Sequence` or `Collection` based on its parameters.
This is a clue that the design is wrong in some fundamental way.  Furthermore,
`Sequence`'s `SubSequence`-creation operations—whose spellings can't involve
indices or subscripts beceause `Sequence` doesn't support them—block progress on
[unifying these slicing
APIs](https://forums.swift.org/t/shorthand-for-offsetting-startindex-and-endindex/9397/83)
under a subscript syntax.

## Why Do We Have `Sequence` and `IteratorProtocol`?

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

where `seq` could have any type conforming to `Sequence`.  It was an extremely
simple model that directly addressed the needs of the `for` loop and could
support trivial generic algorithms such as `reduce`, `map`, and `filter`
besides.

The `Sequence` model was, however, *too* simple to support nontrivial algorithms
such as reverse, sort, and binary search.  The nontrivial algorithms had a
common need to represent, and revisit, a *position*—or *index*—in the sequence.

When we discover that an already-useful protocol lacks the requirements needed
to support an important usage, we have to decide where to add those
requirements: to the original protocol, or to a new *refinement* of the original
protocol.  To make that decision, we ask whether any known models of the
protocol would be unable to efficiently support the new requirement.  This is,
for example, why `BidirectionalCollection` and `RandomAccessCollection` are
distinct protocols: random access is an important capability for some
algorithms, but there is no efficient way for important collections such as
`Dictionary` and `String` to support it.

Some real-world sequences (e.g. a series of network events) only support making
a single pass over the elements.  We'll call these sequences **streams** from
here on to avoid confusion. Our experience with C++ *input iterators* told us
that representing anything like a “position” in such a stream was fraught with
difficulty.  Based on these factors, combined with the high (at the time)
engineering cost associated with changing the way the compiler implemented
`for`...`in` to interact with a more complicated protocol such as `Collection`,
we decided that streams sequences deserved their own protocol…  *without ever
discovering a model that couldn't efficiently support multi-pass traversal*.
Arguably—for a reasonable definition of “efficient”—the
[GeneratorCollection](GeneratorCollection.swift) adapter described below
demonstrates that no such model exists.

## But Sequences Can be Infinite

Currently `Collection` models are required to have a finite number of
elements, but a `Sequence` that is not a `Collection` can be inifinte.
This requirement is motivated as follows in the documentation:

> The fact that all collections are finite guarantees the safety of
> many sequence operations, such as using the `contains(_:)` method to
> test whether a collection includes an element.

It should be noted first off that the comment is misleading: finiteness does not
make any difference to memory safety, which is what “safe” means in Swift.  The
only possible consequence of allowing infinite collections is that some
algorithms might run forever or exhaust memory, neither of which is a safety
problem.

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
`Sequence` as a protocol separate from `Collection`.

## But Some Sequences are Fundamentally Single-Pass

While it's easy to build a `Sequence` that is single-pass as an artifact of how
it is defined, true *streams* are extremely rare.  For example, the following is
only single-pass because of a design choice:

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

A true stream would require significant additional storage or computation to
support multiple passes over its elements.  There are two known cases:

1. The initial state of the element generation procedure, which is
   modified as new elements are generated, is very costly to construct
   and to store, such as in the [Mersenne
   Twister](https://en.wikipedia.org/wiki/Mersenne_Twister)
   pseudo-random number generator.
   
2. The sequence represents some volatile, non-reproducible data stream, such as
   readings from a temperature sensor, or a hardware random number generator.
   Even in some of these cases, the lowest levels of the operating system are
   often buffering input in a way that makes multiple passes possible.
   
## Migrating Existing Code

Removing `Sequence` would break unacceptable amounts of existing code, so I
propose replacing it with the protocol defined in
[Sequence.swift](Sequence.swift), which *refines* `Collection`.  Even so, this
is a disruptive change, which demands careful mitigation.

### Migrating Existing `Sequence` Conformances

Under this proposal, existing types that conform to `Sequence` will newly and
automatically conform to `Collection`.  It will be up to the user to correctly
identify sequences that are true streams and adapt them accordingly (see below),
but there is a heuristic that can be partially automated: an `Iterator` whose
`next` method does not mutate its stored properties, but calls functions with
unknown side-effects, is often consuming the source elements.  False positives
for such a test seem to be rare, but there are examples such as `AnyIterator`
(which would of course be exempted).

### Migrating Existing `Sequence` Constraints

Standard library code that uses `Sequence` as a constraint, but is not already
and separately present on `Collection`, would be changed to use `Collection`
instead. `Sequence` constraints in the wild should be changed to `Collection` as
well.  The immediate need to make this change in user code could be somewhat
mitigated by temporarily extending all standard library `Collection`s so that they also
conform to `Sequence`.

### Adapting Streams

If `Sequence` is no longer going to mean “single-pass,” we'll need some way to
migrate code that is passing a stream to a `Sequence` operation such as
`map`. We can add multipass capability using an adapter that buffers blocks of
elements as they are visited for the first time. The accompanying
[GeneratorCollection.swift](GeneratorCollection.swift) demonstrates.

Needlessly buffering an entire stream would be unacceptable, but traversing a
`GeneratorCollection` just once can be much cheaper than that, as the example
demonstrates: just one block buffer is allocated and reused throughout the
traversal.  This overhead of this block buffer is real, but I argue that in the
rare places it would be needed, it will seldom be significant: true streams
already pay substantial performance costs for their large state, I/O, or both.
In the rare instances where this cost is unacceptable, algorithms can be
overloaded to accept generators.  `Array` initialization is one likely
candidate.

## Open Questions

I've tried to think of everything, but there are still some questions for which
I don't have answers.

### What is the Protocol for Single-Pass Iteration?

Semantically, any stream of `T`s can be captured in a **generator** function of
the form `()->T?`.  Generators avoid the impression given by `Sequence` that it
can be traversed without mutation and by `IteratorProtocol` that it can be
independently copied and stored.  If the need should arise to build generic
systems over single-pass sequences, generators would *almost* work… except that,
as non-nominal types, they can't be extended.  Any algorithm over streams would
have to be defined as a free function, which I think is unacceptable.

One possibility is to not define a protocol at all, but instead, one generic
type that can be extended with algorithms:

```swift
struct Stream<T> {
   public let next: ()->T?
}

extension Stream {
   func map<U>(_ transform: (T)->U) -> [U]
}
```

To properly capture the single-pass nature of streams, though, we need the
ability to express in the type system that any interesting operation *consumes*
the stream.  This capability is expected to arrive with ownership support, but
is not yet available.  In my opinion the problem of how to support single-pass
iteration should be solved when we have full ownership support, and not before.

### How do We Support Move-Only Element Types?

With full ownership support, the language will gain move-only (noncopyable)
types, which are not supported by the signature of `IteratorProtocol.next`,
which returns its argument by value and thus would have to consume the source.
Iteration over an `Array` of move-only types should be a non-mutating operation
that either *borrows*, or gets shared read-only access, to each element.  The
solution to this problem is as yet unknown.

### Whither `IteratorProtocol`?

Geiven everything said above, it's not even clear that `IteratorProtocol` should
exist in the long run.  `Collection` certainly doesn't need the protocol or
associated type: iteration over `c` could be expressed as repeated calls to
`popFront()` on a copy of `c[...]`.  I don't propose to remove it now, but where
it should end up is anybody's guess.

### What about methods like `suffix(n)`?

Today, `x.suffix(n)` is supported by `Collection` with performance O(`count`).
We probably shouldn't have done that.  This method was originally defined only
for `BidirectionalCollection` with O(`n`) performance, but when we discovered
that it was *possible* to implement it for `Sequence` (with reduced performance
guarantees) we went ahead.  However, that meant that `Collection`, which only
had forward iteration, had to support it too.  I'm not sure if there are other
`Collection` methods whose existence there was driven by trying to provide
maximum functionality for `Sequence`, but this one, at least, should be
reconsidered.
