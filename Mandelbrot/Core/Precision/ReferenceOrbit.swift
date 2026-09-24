// The reference orbit perturbation measures every pixel against: computed in
// BigInt fixed point, stored as extended-exponent FloatFloat values in the
// layout Shaders/Perturbation.metal reads, and extendable from where it stopped.

import Foundation

/// ABI shared with Perturbation.metal: each real has a FloatFloat mantissa and
/// an independent signed exponent (a shared complex exponent would erase tiny y).
struct ExtendedFloat: Sendable {
  var mantissa: SIMD2<Float>
  var exponent: Int32
  var padding: Int32 = 0
  init(_ value: WideReal) {
    let hi = Float(value.mantissa)
    mantissa = SIMD2(hi, Float(value.mantissa - Double(hi)))
    exponent = Int32(value.exponent)
  }
  init(_ value: Double) { self.init(WideReal(value)) }
}
struct ExtendedComplex: Sendable {
  var x: ExtendedFloat, y: ExtendedFloat
  init(_ point: DeepPoint) {
    x = ExtendedFloat(point.x.wide)
    y = ExtendedFloat(point.y.wide)
  }
}
struct ReferenceOrbit: Sendable {
  let point: DeepPoint
  let values: [ExtendedComplex]
  let seconds: Double
  let bits: Int
  let iterations: Int
  let escaped: Bool
  var finalX: BigInt? = nil
  var finalY: BigInt? = nil
  var computedSteps: Int = 0
  var storageBytes: Int {
    values.capacity * MemoryLayout<ExtendedComplex>.stride + (bits + 7) / 8 * 4
  }
  static func compute(point: DeepPoint, iterations: Int, bits: Int) throws -> Self {
    try generate(point: point, iterations: iterations, bits: bits, prefix: nil)
  }
  func extended(to iterations: Int) throws -> Self {
    if escaped || iterations <= self.iterations { return self }
    return try Self.generate(point: point, iterations: iterations, bits: bits, prefix: self)
  }
  private static func generate(point: DeepPoint, iterations: Int, bits: Int, prefix: Self?) throws
    -> Self
  {
    let start = ProcessInfo.processInfo.systemUptime
    let cr = point.x.rounded(to: bits).raw
    let ci = point.y.rounded(to: bits).raw
    var x = prefix?.finalX ?? BigInt(0)
    var y = prefix?.finalY ?? BigInt(0)
    let escape = BigInt(65536) << (2 * bits)
    var values: [ExtendedComplex] = prefix?.values ?? []
    var escaped = false
    values.reserveCapacity(min(iterations + 1, 4096))
    let first = prefix?.iterations ?? 0
    if prefix != nil { values.removeLast() }
    for n in first...iterations {
      if n.isMultiple(of: 32) { try Task.checkCancellation() }
      values.append(
        ExtendedComplex(
          DeepPoint(x: DeepNumber(raw: x, bits: bits), y: DeepNumber(raw: y, bits: bits))))
      let xx = x * x
      let yy = y * y
      if xx + yy > escape {
        escaped = true
        break
      }
      if n == iterations { break }
      y = ((2 * x * y) >> bits) + ci
      x = ((xx - yy) >> bits) + cr
    }
    return Self(
      point: point, values: values, seconds: ProcessInfo.processInfo.systemUptime - start,
      bits: bits, iterations: iterations, escaped: escaped, finalX: x, finalY: y,
      computedSteps: max(0, values.count - 1 - first))
  }
}
