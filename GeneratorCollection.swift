// swift -parse-stdlib -Xfrontend -disable-access-control SequenceToCollection.swift
import Swift

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
        typealias OnceContext = (
            myHeader: UnsafeMutableRawPointer,
            initNext: (UnsafeMutableRawPointer)->Void
        )
        
        return withUnsafeMutablePointerToHeader { hPtr in
            withoutActuallyEscaping(generator) { generator in

                var onceContext: OnceContext = (
                    myHeader: UnsafeMutableRawPointer(hPtr),
                    initNext: { rawHeader in
                        rawHeader.assumingMemoryBound(to: Header.self)
                            .pointee.setNext(from: generator)
                    }
                )

                withUnsafeMutablePointer(to: &hPtr.pointee.access) { aPtr in
                    withUnsafeMutablePointer(to: &onceContext) { cPtr in
                        Builtin.onceWithContext(
                            aPtr._rawValue,
                            { rawContextPtr in
                                let context = UnsafePointer<OnceContext>(rawContextPtr).pointee
                                context.initNext(context.myHeader)
                            },
                            cPtr._rawValue
                        )
                    }
                }
            }
            return hPtr.pointee._next.unsafelyUnwrapped
        }
    }

    struct Header {
        var _next: GeneratorBuffer?
        var access: Int
        var count: Int

        fileprivate mutating func setNext(from generator: ()->T?) {
            if let first = generator() {
                _next = GeneratorBuffer.create(
                    minimumCapacity: count,
                    first: first, rest: generator
                )
            }
            else {
                _next = unsafeBitCast(
                    emptyBuffer, to: GeneratorBuffer<T>.self)
            }
        }
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
        i.offsetInBuffer += 1
        if i.offsetInBuffer < i.buffer.header.count { return }

        if let nextBuffer = isKnownUniquelyReferenced(&i.buffer)
            ? i.buffer.header._next : i.buffer.next(from: generator)
        {
            if nextBuffer.header.count == 0 {
                i = endIndex
            }
            else {
                i.buffer = nextBuffer
                i.offsetInBuffer = 0
                i.bufferNumber += 1
            }
            return
        }
        assert(isKnownUniquelyReferenced(&i.buffer))
        
        if let first = generator() {
            i.buffer.fill(first: first, rest: generator)
            i.offsetInBuffer = 0
            i.bufferNumber += 1
        }
        else {
            i.buffer.header._next = endIndex.buffer
            i = endIndex
        }
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
    
    let generator: ()->T?
}

extension GeneratorCollection.Index : Comparable {
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
