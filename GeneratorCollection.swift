// swift -parse-stdlib -Xfrontend -disable-access-control SequenceToCollection.swift
import Swift

/// Exactly once, regulated by `access` pointing to a zero-initialized
/// `Int` not on the stack, invoke `writer(&target)`.
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

public final class GeneratorBuffer<T>
  : ManagedBuffer<GeneratorBuffer.Header, T> {
    public static func create(
        minimumCapacity: Int,
        first: T,
        rest: ()->T?
        ) -> GeneratorBuffer {
        let r = super.create(
            minimumCapacity: minimumCapacity
        ) { _ in Header(_next: nil, access: 0, count: 0) }
        as! GeneratorBuffer
        
        r.fill(first: first, rest: rest)
        return r
    }
    
    private init() { fatalError("do not call me") }
    
    deinit {
        _ = withUnsafeMutablePointerToElements {
            $0.deinitialize(count: header.count)
        }
    }
    
    func fill(first: T, rest: ()->T?) {
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

    /// Returns the next GeneratorBuffer in the sequence, retrieving
    /// elements if necessary by calling `generator`.
    func next(from generator: ()->T?) -> GeneratorBuffer {
        return withUnsafeMutablePointerToHeader { hPtr in
            once(
                regulatedBy: &hPtr[0].access,
                modify: &hPtr[0]._next
            ) { next in
                if let first = generator() {
                    next = GeneratorBuffer.create(
                        minimumCapacity: hPtr[0].count,
                        first: first, rest: generator
                    )
                }
                else {
                    next = unsafeBitCast(
                        emptyBuffer, to: GeneratorBuffer<T>.self)
                }
            }
            return hPtr[0]._next.unsafelyUnwrapped
        }
    }

    struct Header {
        var _next: GeneratorBuffer?
        var access: Int
        var count: Int
    }
}

extension GeneratorBuffer where T == Void {
    static func makeEmpty() -> GeneratorBuffer {
        let r = create(minimumCapacity: 1, first: ()) { return nil }
        r.header.count = 0
        return r
    }
}

let emptyBuffer = GeneratorBuffer<Void>.makeEmpty()

public struct GeneratorCollection<T> : Collection {
    public struct Index {
        var bufferNumber: UInt = UInt.max
        var offsetInBuffer: Int = 0
        var buffer: GeneratorBuffer<T>
            = unsafeBitCast(emptyBuffer, to: GeneratorBuffer<T>.self)
    }

    public struct Slice_ {
        public private(set) var startIndex, endIndex: Index
        public private(set) var generator: ()->T?
    }
    public typealias SubSequence = Slice_
    
    static func emptyGenerator() -> T? { return nil }
    
    public init(generator: @escaping ()->T?) {
        guard let first = generator() else {
            self.generator = GeneratorCollection.emptyGenerator
            self.startIndex = Index()
            return
        }
        
        self.generator = generator
        startIndex = Index(
            bufferNumber: 0,
            offsetInBuffer: 0,
            buffer: GeneratorBuffer<T>.create(
                minimumCapacity: 15, first: first, rest: generator)
        )
    }
    
    public let startIndex: Index
    
    public var endIndex: Index {
        return Index()
    }
    
    public func formIndex(after i: inout Index) {
        i.stepForward(generator: generator)
    }
    
    public func index(after i: Index) -> Index {
        var j = i
        formIndex(after: &j)
        return j
    }
    
    public subscript(i: Index) -> T {
        return i.buffer.withUnsafeMutablePointerToElements {
            $0[i.offsetInBuffer]
        }
    }

    public subscript(bounds: Range<Index>) -> Slice_ {
        return Slice_(
            startIndex: bounds.lowerBound,
            endIndex: bounds.upperBound,
            generator: generator
        )
    }

    public var underestimatedCount: Int {
        return startIndex.buffer.header.count
           - startIndex.offsetInBuffer
    }
    
    let generator: ()->T?
}

extension GeneratorCollection.Slice_ : Collection {
    public typealias Index = GeneratorCollection.Index
    public typealias Element = T
    public typealias SubSequence = GeneratorCollection.Slice_
    
    public subscript(i: Index) -> T {
        return i.buffer.withUnsafeMutablePointerToElements {
            $0[i.offsetInBuffer]
        }
    }

    public subscript(bounds: Range<Index>) -> SubSequence {
        return SubSequence(
            startIndex: bounds.lowerBound,
            endIndex: bounds.upperBound,
            generator: generator
        )
    }

    public func formIndex(after i: inout Index) {
        i.stepForward(generator: generator)
    }
    
    public func index(after i: Index) -> Index {
        var j = i
        formIndex(after: &j)
        return j
    }
    
    public var underestimatedCount: Int {
        return startIndex.buffer.header.count
           - startIndex.offsetInBuffer
    }
}

extension GeneratorCollection.Index : Comparable {
    fileprivate mutating func stepForward(generator: ()->T?) {
        offsetInBuffer += 1
        if offsetInBuffer < buffer.header.count { return }

        if isKnownUniquelyReferenced(&buffer) {
            print("Why doesn't this check ever fire?")
        }
        
        if let nextBuffer = isKnownUniquelyReferenced(&buffer)
            ? buffer.header._next : buffer.next(from: generator)
        {
            if nextBuffer.header.count == 0 {
                self = GeneratorCollection.Index()
            }
            else {
                buffer = nextBuffer
                offsetInBuffer = 0
                bufferNumber += 1
            }
            return
        }
        assert(isKnownUniquelyReferenced(&buffer))
        
        if let first = generator() {
            buffer.fill(first: first, rest: generator)
            offsetInBuffer = 0
            bufferNumber += 1
        }
        else {
            let next = GeneratorCollection.Index()
            buffer.header._next = next.buffer
            self = next
        }
    }
    
    public static func == (
        l: GeneratorCollection.Index, r: GeneratorCollection.Index
    ) -> Bool {
        return (l.bufferNumber, l.offsetInBuffer) ==
            (r.bufferNumber, r.offsetInBuffer)
    }
    
    public static func < (
        l: GeneratorCollection.Index, r: GeneratorCollection.Index
    ) -> Bool {
        return (l.bufferNumber, l.offsetInBuffer) <
            (r.bufferNumber, r.offsetInBuffer)
    }
}

func makeGenerator() -> ()->Int? {
    var i = (0...100).makeIterator()
    return { i.next() }
}

print(Array(GeneratorCollection(generator: makeGenerator())))

func testUnique() {
    var a: [Int] = []
    var source = GeneratorCollection(generator: makeGenerator())[...]
    while let x = source.popFirst() {
        a.append(x)
    }
    print(a)
}

testUnique()

// Local Variables:
// swift-basic-offset: 4
// fill-column: 80
// End:
