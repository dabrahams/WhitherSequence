// swift -parse-stdlib -Xfrontend -disable-access-control SequenceToCollection.swift
import Swift
import Dispatch
extension ManagedBuffer {
    @_inlineable
    public final class func unsafeCreateUninitialized(
        minimumCapacity: Int
        ) -> ManagedBuffer<Header, Element> {
        return Builtin.allocWithTailElems_1(
            self,
            minimumCapacity._builtinWordValue, Element.self)
    }
}

public final class GeneratorBuffer<T> : ManagedBuffer<(), T> {
    public static func create(
        minimumCapacity: Int,
        first: T,
        rest: ()->T?
        ) -> GeneratorBuffer {
        let r = unsafeCreateUninitialized(
            minimumCapacity: minimumCapacity
            ) as! GeneratorBuffer
        
        withUnsafeMutablePointer(to: &r._next) { $0.initialize(to: nil) }
        withUnsafeMutablePointer(to: &r.access) { $0.initialize(to: 0) }
        withUnsafeMutablePointer(to: &r.count) { $0.initialize(to: 0) }
        r.fill(first: first, rest: rest)
        return r
    }
    
    private init() { fatalError("do not call me") }
    
    deinit {
        _ = withUnsafeMutablePointerToElements {
            $0.deinitialize(count: count)
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
        self.count = n
    }
    
    private func address<T>(
        of x: inout T
        ) -> UnsafeMutablePointer<T> {
        return withUnsafeMutablePointer(to: &x) { $0 }
    }
    
    func next(from generator: ()->T?) -> GeneratorBuffer {
        typealias Context = (
            thisBuffer: UnsafeMutableRawPointer,
            initNext: (UnsafeMutableRawPointer)->Void
        )
        
        withoutActuallyEscaping(generator) { generator in
            var context: Context = (
                thisBuffer: Unmanaged.passUnretained(self).toOpaque(),
                initNext: { rawSelf in
                    let myself = Unmanaged<GeneratorBuffer>.fromOpaque(rawSelf)
                        .takeUnretainedValue()
                    
                    if let first = generator() {
                        myself._next = GeneratorBuffer.create(
                            minimumCapacity: myself.count,
                            first: first, rest: generator
                        )
                    }
                    else {
                        myself._next = unsafeBitCast(
                            emptyBuffer, to: GeneratorBuffer<T>.self)
                    }
                }
            )
            
            Builtin.onceWithContext(
                address(of: &self.access)._rawValue,
                { rawContextPtr in
                    let context = UnsafePointer<Context>(rawContextPtr).pointee
                    context.initNext(context.thisBuffer)
                },
                address(of: &context)._rawValue
            )
        }
        _fixLifetime(self)
        return _next!
    }
    
    var _next: GeneratorBuffer?
    var access: Int
    var count: Int
}

extension GeneratorBuffer where T == Void {
    static func makeEmpty() -> GeneratorBuffer {
        let r = create(minimumCapacity: 1, first: ()) { return nil }
        r.count = 0
        return r
    }
}

let emptyBuffer = GeneratorBuffer<Void>.makeEmpty()

struct GeneratorCollection<T> : Collection {
    struct Index {
        var bufferNumber: UInt = UInt.max
        var offsetInBuffer: Int = 0
        var buffer: GeneratorBuffer<T>
            = unsafeBitCast(emptyBuffer, to: GeneratorBuffer<T>.self)
    }
    
    static func emptyGenerator() -> T? { return nil }
    
    init(generator: @escaping ()->T?) {
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
    
    let startIndex: Index
    
    var endIndex: Index {
        return Index()
    }
    
    func formIndex(after i: inout Index) {
        i.offsetInBuffer += 1
        if i.offsetInBuffer < i.buffer.count { return }

        if let nextBuffer = false // isKnownUniquelyReferenced(&i.buffer)
            ? i.buffer._next : i.buffer.next(from: generator)
        {
            if nextBuffer.count == 0 {
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
            i.buffer._next = endIndex.buffer
            i = endIndex
        }
    }
    
    func index(after i: Index) -> Index {
        var j = i
        formIndex(after: &j)
        return j
    }
    
    subscript(i: Index) -> T {
        return i.buffer.withUnsafeMutablePointerToElements {
            $0[i.offsetInBuffer]
        }
    }
    
    let generator: ()->T?
}

extension GeneratorCollection.Index : Comparable {
    static func == (
        l: GeneratorCollection.Index, r: GeneratorCollection.Index
    ) -> Bool {
        return (l.bufferNumber, l.offsetInBuffer) ==
            (r.bufferNumber, r.offsetInBuffer)
    }
    
    static func < (
        l: GeneratorCollection.Index, r: GeneratorCollection.Index
    ) -> Bool {
        return (l.bufferNumber, l.offsetInBuffer) <
            (r.bufferNumber, r.offsetInBuffer)
    }
}

func makeGenerator() -> ()->Int? {
    var i = (0...10).makeIterator()
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
