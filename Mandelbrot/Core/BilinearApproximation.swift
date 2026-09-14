import Foundation

/// A bounded BLA block: delta' = A*delta + B*deltaC. Coefficients retain their
/// exponent when sent to Metal. Zero radius means 'perform ordinary iterations'.
struct BLAEntry: Sendable {
  var a, b: ExtendedComplex
  var radius: ExtendedFloat
  var length: UInt32
  var padding0: UInt32 = 0, padding1: UInt32 = 0, padding2: UInt32 = 0
}
private struct BLAComplex {
  var x: Double, y: Double
  var magnitude: Double { hypot(x, y) }
  static func * (a: Self, b: Self) -> Self {
    Self(x: a.x * b.x - a.y * b.y, y: a.x * b.y + a.y * b.x)
  }
  static func + (a: Self, b: Self) -> Self { Self(x: a.x + b.x, y: a.y + b.y) }
  var packed: ExtendedComplex { ExtendedComplex(x: ExtendedFloat(x), y: ExtendedFloat(y)) }
}
extension ExtendedComplex {
  init(x: ExtendedFloat, y: ExtendedFloat) {
    self.x = x
    self.y = y
  }
}
extension ExtendedFloat {
  var double: Double {
    WideReal(Double(mantissa.x) + Double(mantissa.y), exponent: Int(exponent)).double
  }
}
enum BilinearApproximation {
  static let blockLength = 32
  static func build(orbit: ReferenceOrbit, maximumDelta: WideReal) throws -> [BLAEntry] {
    var result: [BLAEntry] = []
    // A conservative upper bound; conversion underflow is rounded UP to the
    // smallest normal Double, so radius construction never understates |dc|.
    let dc = max(Double.leastNormalMagnitude, maximumDelta.double)
    for start in stride(from: 1, to: orbit.values.count, by: blockLength) {
      try Task.checkCancellation()
      var a = BLAComplex(x: 1, y: 0)
      var b = BLAComplex(x: 0, y: 0)
      var radius = Double.greatestFiniteMagnitude
      let length = min(blockLength, orbit.values.count - 1 - start)
      for n in start..<(start + length) {
        let z = orbit.values[n]
        let norm = hypot(z.x.double, z.y.double)
        let factor = BLAComplex(x: 2 * z.x.double, y: 2 * z.y.double)
        // Keep every intermediate orbit far from a glitch or bailout, and
        // the omitted quadratic term below FloatFloat precision with margin.
        let local = norm < 128 ? pow(2, -44) * norm / (factor.magnitude + 1) : 0
        if a.magnitude > 0 {
          radius = min(radius, max(0, (local - b.magnitude * dc) / a.magnitude))
        } else {
          radius = 0
        }
        b = factor * b + BLAComplex(x: 1, y: 0)
        a = factor * a
      }
      if length < 2 || !radius.isFinite { radius = 0 }
      result.append(
        BLAEntry(a: a.packed, b: b.packed, radius: ExtendedFloat(radius), length: UInt32(length)))
    }
    if result.isEmpty {
      result.append(
        BLAEntry(
          a: BLAComplex(x: 0, y: 0).packed, b: BLAComplex(x: 0, y: 0).packed,
          radius: ExtendedFloat(0), length: 0))
    }
    return result
  }
}

/// Small global cache only used by tiles. Full-image benchmarks intentionally
/// create fresh orbits. Its 4 MiB cap is covered by the tile transient reserve.
actor ReferenceOrbitCache {
  static let shared = ReferenceOrbitCache()
  private struct Entry {
    let point: DeepPoint, iterations: Int, bits: Int, orbit: ReferenceOrbit
  }
  private var entries: [Entry] = []
  func reference(point: DeepPoint, iterations: Int, bits: Int) throws -> (ReferenceOrbit, Bool) {
    try Task.checkCancellation()
    if let index = entries.firstIndex(where: {
      $0.point == point && $0.iterations == iterations && $0.bits == bits
    }) {
      let entry = entries.remove(at: index)
      entries.append(entry)
      return (entry.orbit, true)
    }
    let orbit = try ReferenceOrbit.compute(point: point, iterations: iterations, bits: bits)
    let bytes = orbit.values.count * MemoryLayout<ExtendedComplex>.stride
    while !entries.isEmpty
      && (entries.count >= 3
        || entries.reduce(
          bytes, { $0 + $1.orbit.values.count * MemoryLayout<ExtendedComplex>.stride }) > 4 * 1024
          * 1024)
    {
      entries.removeFirst()
    }
    if bytes <= 4 * 1024 * 1024 {
      entries.append(Entry(point: point, iterations: iterations, bits: bits, orbit: orbit))
    }
    return (orbit, false)
  }
}
