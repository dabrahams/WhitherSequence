// Components that allow the rare sequence that actually *is* single-pass to
// easily be converted into a `Collection`.
//
// In this file, to emphasize the fact that we can actually eliminate `Sequence`
// and `Iterator`, we represent the concept of "single-pass sequence" as any
// function returning `Optional<Element>`.  Given any `Sequence` `s` of
// `Element` type `T`, the following code produces a corresponding generator:
//
//     let g: ()->T? = { var i = s.makeIterator(); return { i.next() } }()
//

// Note: Some code below uses Builtin primitives that are normally only
// available to the standard library.  To build, please add the -parse-stdlib
// flag to your swift invocation.
import Swift

//===--- Utilities --------------------------------------------------------===//

/// Thread-safely invokes `writer(&target)` iff `access.pointee` is zero.
///
/// - Precondition: `access` does not point at (or into) a local variable.
/// - Postcondition: `access.pointee` is nonzero.
///
/// Use `once` when it's possible that multiple threads may need to contend to
/// modify `target`, and it only needs to be modified once, or it can be
/// guaranteed that resetting `access.pointee` to zero has been made visible to
/// all threads.
/// 
func once<T>(
    regulatedBy access: UnsafeMutablePointer<Int>,
    modify target: inout T,
    applying writer: (inout T)->Void
) {
    // We can't capture any generic type information in the 'C'
    // function passed to Builtin.onceWithContext, so we'll need go
    // through a thunk.
    
    /// A type-erased package for the expression `writer(&target)`
    typealias Thunk = (
        initialize: (UnsafeMutableRawPointer)->Void,
        target: UnsafeMutableRawPointer
    )
    
    // Although we'll store writer in the thunk, the thunk is never
    // copied, so there's no actual escaping.
    withoutActuallyEscaping(writer) { writer in
        withUnsafeMutablePointer(to: &target) { targetPtr in
            // Prepare the thunk
            var thunk = Thunk(
                initialize: { p in
                    let targetPtr = p.assumingMemoryBound(to: T.self)
                    writer(&targetPtr.pointee)
                },
                target: UnsafeMutableRawPointer(targetPtr)
            )

            withUnsafePointer(to: &thunk) { thunkPtr in
                // Use it as the context for the builtin.
                Builtin.onceWithContext(
                    access._rawValue,
                    { 
                        let thunk = UnsafePointer<Thunk>($0).pointee
                        thunk.initialize(thunk.target)
                    },
                    thunkPtr._rawValue
                )
            }
        }
    }
}

//===--- Implementation ---------------------------------------------------===//

/// A buffer of `T`s produced by a generator.
///
/// This buffer participates in a linked list of segments extracted in order from
/// the generator.  We use a strategy similar to COW: when multiply-referenced,
/// the buffer is entirely immutable except for its `next` field in the linked
/// list, which is (thread-safely) filled on demand.
private final class GeneratorBuffer<T>
    : ManagedBuffer<GeneratorBuffer.Header, T> 
{
    /// Non-element storage
    fileprivate struct Header {
        /// The next buffer in the chain, if known.
        ///
        /// NOT safe to access from multiple threads without synchronization.
        var _next: GeneratorBuffer?

        /// Multithread synchronization token for initializing `_next`
        var access: Int

        /// The number of elements stored.
        var count: Int
    }
    
    /// Returns an instance having at least the given `minimumCapacity`,
    /// containing `first` followed by as many elements as are generated by
    /// `rest` and fit in the allocated space.
    public static func create(
        minimumCapacity: Int,
        first: T,
        rest: ()->T?
    ) -> GeneratorBuffer {
        let r = super.create(
            minimumCapacity: max(minimumCapacity, 1)
        ) { _ in Header(_next: nil, access: 0, count: 0) }
        as! GeneratorBuffer
        
        r.fill(first: first, rest: rest)
        return r
    }
    
    private init() { fatalError("do not call me; use create() instead") }

    deinit {
        // deinitialize any elements before we go
        _ = withUnsafeMutablePointerToElements {
            $0.deinitialize(count: header.count)
        }
    }

    /// Sets the content to `first` followed by as many elements as are
    /// generated by `rest` and fit in the allocated space.
    fileprivate func fill(first: T, rest: ()->T?) {
        let maxCount = capacity
        var n = 1
        withUnsafeMutablePointerToElements {
            elements in
            elements.initialize(to: first)
            while n < maxCount, let e = rest() {
                (elements + n).initialize(to: e)
                n += 1
            }
        }
        self.header.count = n
    }

    /// An empty buffer that's used as the tail of all buffer chains whose
    /// generators have been exhausted.
    fileprivate static var emptyBuffer: GeneratorBuffer {
        // All buffers share the same emptyBuffer for efficiency.
        return unsafeBitCast(_emptyBuffer, to: GeneratorBuffer<T>.self)
    }
    
    /// Returns the next GeneratorBuffer, filling it if it doesn't already exist
    /// with elements from `generator`.
    ///
    /// - Note: this method is safe to call from multiple threads.
    public func next(from generator: ()->T?) -> GeneratorBuffer {
        return withUnsafeMutablePointerToHeader { h in
            once(regulatedBy: &h[0].access, modify: &h[0]._next) { next in
                guard let first = generator() else {
                    next = .emptyBuffer
                    return
                }
                next = GeneratorBuffer.create(
                    minimumCapacity: h[0].count, first: first, rest: generator)
            }
            return h[0]._next.unsafelyUnwrapped
        }
    }
}

//===--- `emptyBuffer` support --------------------------------------------===//
// Similar to `Array<T>`, all `GeneratorBuffer<T>`s share the same `emptyBuffer`
// instance.  
extension GeneratorBuffer where T == Void {
    /// Create an empty buffer that lives forever
    fileprivate static func makeEmpty() -> GeneratorBuffer {
        let r = create(minimumCapacity: 1, first: ()) { return nil }
        r.header.count = 0
        r.header._next = r 
        // The above is a reference loop.  Not necessessary for correctness at
        // the time of this writing, but is probably the right thing to do since
        // the _next field is not yet-to-be-determined: any chain ending here
        // has had its generator exhausted.
        return r
    }
}

// If this code were in the standard library, we would have a
// statically-allocated piece of storage for the canonical empty buffer.  Here
// we must use
private let _emptyBuffer = GeneratorBuffer<Void>.makeEmpty()

/// A `Collection` of elements produced by a generator.
///
/// `GeneratorCollection` is "semi-lazy" in that it eagerly pulls up to a given
/// *block size* of elements from the generator, and thereafter only pulls
/// additional blocks of elements on demand.
public struct GeneratorCollection<T> {
    /// Where the elements come from.
    private let source: ()->Element?

    /// The position of the first element, or `endIndex` if `self` is empty.
    public let startIndex: Index

    // FIXME: 15 is almost certainly the wrong default below, but it allows us
    // to observe the code working wiht smaller numbers of elements.
    
    /// Creates an instance with initial storage for at least `blockSize`
    /// elements, consuming as many as fit in the storage from `source`.
    ///
    /// - Note: The instance and its slices have the exclusive right to invoke
    ///   `source` from this point forward.  The argument passed should be
    ///   considered uncallable once instance construction has been initiated.
    public init(blockSize: Int = 15, source: @escaping ()->T?) {

        // The empty source is a special case for which we can avoid allocating
        // a buffer.
        guard let first = source() else {
            self.source = { return nil }
            self.startIndex = Index()
            return
        }
        
        self.source = source
        startIndex = Index(
            segmentNumber: 0,
            offsetInSegment: 0,
            segment: GeneratorBuffer<T>.create(
                minimumCapacity: blockSize, first: first, rest: source)
        )
    }
}

extension GeneratorCollection : Collection {
    /// A position in this collection.
    ///
    /// Valid indices consist of the position of every element and a
    /// "past the end" position that's not valid for use as a subscript
    /// argument.
    public struct Index {
        /// The ordinal number of `segment` in the generated list.
        fileprivate var segmentNumber: UInt = UInt.max
        /// The index of the referenced element.
        fileprivate var offsetInSegment: Int = 0
        /// The buffer containing the referenced element
        fileprivate var segment = GeneratorBuffer<T>.emptyBuffer
    }

    /// A contiguous subrange of the `GeneratorCollection`'s
    /// elements.
    ///
    /// - Note: repeatedly dropping or popping elements from the front allows
    ///   storage for unreachable elements to be reclaimed.
    public struct SubSequence {
        public private(set) var startIndex, endIndex: Index
        fileprivate private(set) var source: ()->T?
    }
    
    public var endIndex: Index {
        return Index()
    }
    
    public func formIndex(after i: inout Index) {
        i.stepForward(pullingFrom: source)
    }
    
    public func index(after i: Index) -> Index {
        var j = i
        j.stepForward(pullingFrom: source)
        return j
    }
    
    public subscript(i: Index) -> T {
        return i.segment.withUnsafeMutablePointerToElements {
            $0[i.offsetInSegment]
        }
    }

    public subscript(bounds: Range<Index>) -> SubSequence {
        return SubSequence(
            startIndex: bounds.lowerBound,
            endIndex: bounds.upperBound,
            source: source
        )
    }

    public var underestimatedCount: Int {
        return startIndex.segment.header.count - startIndex.offsetInSegment
    }
}

extension GeneratorCollection.SubSequence : Collection {
    public typealias Index = GeneratorCollection.Index
    public typealias Element = T
    public typealias SubSequence = GeneratorCollection.SubSequence
    
    public subscript(i: Index) -> T {
        return i.segment.withUnsafeMutablePointerToElements {
            $0[i.offsetInSegment]
        }
    }

    public subscript(bounds: Range<Index>) -> SubSequence {
        return SubSequence(
            startIndex: bounds.lowerBound,
            endIndex: bounds.upperBound,
            source: source
        )
    }

    public func formIndex(after i: inout Index) {
        i.stepForward(pullingFrom: source)
    }
    
    public func index(after i: Index) -> Index {
        var j = i
        j.stepForward(pullingFrom: source)
        return j
    }
    
    public var underestimatedCount: Int {
        return startIndex.segment.header.count - startIndex.offsetInSegment
    }
    
    // The following is needed because of https://bugs.swift.org/browse/SR-7167.
    // Otherwise our "popFirst" rendition of the for...in loop fails to re-use
    // the same buffer.
    
    /// Removes and returns the first element of the collection.
    ///
    /// - Returns: The first element of the collection if the collection is
    ///   not empty; otherwise, `nil`.
    ///
    /// - Complexity: O(1)
    public mutating func popFirst() -> Element? {
        guard !isEmpty else { return nil }
        let r = self[startIndex]
        startIndex.stepForward(pullingFrom: source)
        return r
    }
}


extension GeneratorCollection.Index : Comparable {
    public static func == (
        l: GeneratorCollection.Index, r: GeneratorCollection.Index
    ) -> Bool {
        return (l.segmentNumber, l.offsetInSegment) ==
            (r.segmentNumber, r.offsetInSegment)
    }
    
    public static func < (
        l: GeneratorCollection.Index, r: GeneratorCollection.Index
    ) -> Bool {
        return (l.segmentNumber, l.offsetInSegment) <
            (r.segmentNumber, r.offsetInSegment)
    }
}

extension GeneratorCollection.Index {
    /// Move forward one position in the collection, if necessary pulling
    /// elements to fill a new buffer from `source`.
    fileprivate mutating func stepForward(pullingFrom source: ()->T?) {
        offsetInSegment += 1
        if offsetInSegment < segment.header.count { return }

        // if the segment is uniquely-referenced, no other thread has it and we
        // can safely read the _next field directly.  
        if let nextSegment = isKnownUniquelyReferenced(&segment)
            ? segment.header._next : segment.next(from: source)
        {
            if nextSegment.header.count == 0 {
                self = GeneratorCollection.Index()
            }
            else {
                segment = nextSegment
                offsetInSegment = 0
                segmentNumber += 1
            }
            return
        }
        
        // segment.next() always returns non-nil, so we have a unique reference.
        assert(isKnownUniquelyReferenced(&segment))

        if let first = source() {
            // refill and re-use the same buffer.
            print("refilling...")
            segment.fill(first: first, rest: source)
            offsetInSegment = 0
            segmentNumber += 1
        }
        else {
            // we're at a definitive end; link the empty buffer into the chain.
            let nextSelf = GeneratorCollection.Index()
            segment.header._next = nextSelf.segment
            self = nextSelf
        }
    }
}

//===--- Tests ------------------------------------------------------------===//

/// Returns a simple generator of Ints from 0...100
func makeGenerator() -> ()->Int? {
    var i = (0...100).makeIterator()
    return { i.next() }
}

// Build a GeneratorCollection
let g = GeneratorCollection(source: makeGenerator())

print(Array(g)) // It has the right contents

// Basic indexing operations work.
print(g[g.index(of: 13)!], g[g.index(of: 14)!], g[g.index(of: 15)!])
print(g[g.index(of: 28)!], g[g.index(of: 29)!], g[g.index(of: 30)!])
print(g.index(of: 200) == nil)

func testForLoopTranslation() {
    var a: [Int] = []
    // Proposed implementation of
    //
    //    for x in GeneratorCollection(source: makeGenerator()) { a.append(x) }
    var source = GeneratorCollection(source: makeGenerator())[...]
    while let x = source.popFirst() { a.append(x) }

    // See that we got there
    print(a)
}

testForLoopTranslation()

// Local Variables:
// swift-basic-offset: 4
// fill-column: 80
// End:
