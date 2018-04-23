// Based heavily on the work of Nathan Merseth Cook

// Demonstrates usage of the proposed new Sequence convenience
func test() {
  
  // This would just be a Sequence in existing Swift but with the definitions
  // below, it conforms to Collection.
  struct Fibonacci: Sequence, IteratorProtocol {
    var n = 0
    var m = 1
    
    mutating func next() -> Int? {
      let r = n
      (n, m) = (m, n + m)
      return r
    }
    
    // Workaround for https://bugs.swift.org/browse/SR-7499
    typealias Iterator = Fibonacci
  }

  // Print the first 9; this worked with the existing Sequence.
  let s = Fibonacci()
  print(Array(s.prefix(9)))                    // [0, 1, 1, 2, 3, 5, 8, 13, 21]


  // Now do things that require collection conformance.
  let i = s.index(where: { $0 > 6 })!
  print(Array(s[i...].prefix(5)))              // [8, 13, 21, 34, 55]

  // Binary search for the index of the first element >= 1000
  let s2 = Fibonacci().prefix(90)
  let j = s2.distance(from: s2.startIndex, to: s2.partitionPoint { $0 >= 1000 })
  print(j)                                     // 17
}

//===----------------------------------------------------------------------===//
// Replacement for existing Sequence that uses the same requirements to define
// Collections.
//===----------------------------------------------------------------------===//

/// A convenience for simply defining Collections.
protocol Sequence : Collection {}

/// Collection conformance
extension Sequence {
  var startIndex: SequenceIndex<Self> {
    return SequenceIndex(self)
  }
  
  var endIndex: SequenceIndex<Self> {
    return SequenceIndex()
  }
  
  subscript(i: SequenceIndex<Self>) -> Iterator.Element {
    return i.element
  }
  
  func index(after i: SequenceIndex<Self>) -> SequenceIndex<Self> {
    var j = i
    j.stepForward()
    return j
  }
  
  func formIndex(after i: inout SequenceIndex<Self>) {
    i.stepForward()
  }

  typealias SubSequence = MultipassSubSequence<Self>
  subscript(r: Range<SequenceIndex<Self>>) -> MultipassSubSequence<Self> {
    return MultipassSubSequence(
      startIndex: r.lowerBound,
      endIndex: r.upperBound
    )
  }
}

/// A default `Index` type for `Collection`s defined using `Sequence`.
enum SequenceIndex<Base: Swift.Sequence> : Comparable {

  init() { self = .end }

  init(_ s: Base) {
    var i = s.makeIterator()
    if let e = i.next() {
      self = .element(0, e, i)
    }
    else {
      self = .end
    }
  }

  /// An index of an element in the collection.
  ///
  /// The associated values are:
  /// - The zero-based position in the collection, for `Comparable` purposes.
  /// - The element itself, so that it only needs to be computed once.
  /// - The state, immediately after generating the element at this index.
  case element(Int, Base.Element, Base.Iterator)
  
  /// An index representing the end of the collection.
  case end
  
  static func ==(lhs: SequenceIndex, rhs: SequenceIndex) -> Bool {
    switch (lhs, rhs) {
      case let (.element(l, _, _), .element(r, _, _)): return l == r
      case (.end, .end): return true
      default: return false
    }
  }
  
  static func < (lhs: SequenceIndex, rhs: SequenceIndex) -> Bool {
    switch (lhs, rhs) {
      case let (.element(l, _, _), .element(r, _, _)): return l < r
      case (.element, .end): return true
      default: return false
    }
  }

  mutating func stepForward() {
    switch self {
      case .element(let pos, _, var iterator):
        if let e = iterator.next() {
          self = .element(pos + 1, e, iterator)
        } else {
          self = .end
        }
      case .end:
        fatalError("Can't advance past end")
    }
  }

  func distance(to other: SequenceIndex) -> Int {
    switch (self, other) {
      case (.end, .end): return 0
      case (.element(let l, _, _), .element(let r, _, _)): return r - l
      default: break
    }
    var i = self
    var n = 0
    while i != .end { i.stepForward(); n += 1 }
    return n
  }

  var element: Base.Element {
    guard case .element(_, let e, _) = self else {
      fatalError("Can't subscript at end")
    }
    return e
  }
}

/// A default `SubSequence` type for `Collection`s defined using `Sequence`.
struct MultipassSubSequence<Base: Sequence> : Collection {
  typealias Element = Base.Element
  typealias Index = SequenceIndex<Base>
  typealias SubSequence = MultipassSubSequence
  
  let startIndex, endIndex: Index

  subscript(i: Index) -> Iterator.Element {
    return i.element
  }
  
  func index(after i: Index) -> Index {
    var j = i
    j.stepForward()
    return j
  }
  
  func formIndex(after i: inout Index) {
    i.stepForward()
  }

  subscript(r: Range<SequenceIndex<Base>>) -> MultipassSubSequence {
    return MultipassSubSequence(
      startIndex: r.lowerBound,
      endIndex: r.upperBound
    )
  }
}

//===--- Define Binary Search for Collections -----------------------------===//
extension Collection {
  /// Returns the index of the first element in the collection
  /// that matches the predicate.
  ///
  /// The collection must already be partitioned according to the
  /// predicate, as if `self.partition(by: predicate)` had already
  /// been called.
  func partitionPoint(
    where predicate: (Element) throws -> Bool
  ) rethrows -> Index {
    var n = count
    var l = startIndex

    while n > 0 {
      let half = n / 2
      let mid = index(l, offsetBy: half)
      if try predicate(self[mid]) {
        n = half
      } else {
        l = index(after: mid)
        n -= half + 1
      }
    }
    return l
  }
}

test()

// Local Variables:
// swift-basic-offset: 2
// End:
