import Foundation
import Testing

@testable import MandelbrotCore

@Test func extendedBLACoefficientsAndHierarchy() throws {
  // A constant Z=2 orbit makes A=4^length: a long merged coefficient exceeds
  // Double's range while its valid radius remains representable in wide form.
  let point = DeepPoint(CGPoint(x: -2, y: 0), bits: 192)
  let orbit = ReferenceOrbit(
    point: point,
    values: Array(
      repeating: ExtendedComplex(DeepPoint(CGPoint(x: 2, y: 0), bits: 192)), count: 2049),
    seconds: 0, bits: 192, iterations: 2048, escaped: false)
  let table = try BilinearApproximation.build(
    orbit: orbit, maximumDelta: WideReal(1, exponent: -10000))
  let root = table.entries[1]
  #expect(root.length == 2047)
  #expect(root.a.x.exponent > 1024)
  #expect(root.a.x.mantissa.x.isFinite && root.radius.mantissa.x > 0)
  #expect(root.radius.exponent < -1024)
  #expect(table.entries[table.leafOffset].length == 32)
  let a = WideReal(1, exponent: 4000)
  let b = WideReal(1, exponent: 3999)
  #expect((a + b).divided(by: a).double == 1.5)
  #expect((b - a) < WideReal(0))
  #expect((a * WideReal(1, exponent: -4000)).double == 1)
}
