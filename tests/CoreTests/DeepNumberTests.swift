import Foundation
import Testing
@testable import MandelbrotCore

@Test func deepDecimalsRetainSubDoubleOffsets() throws {
  let a = try DeepNumber(decimal: "-2", bits: 3500)
  let epsilon = try DeepNumber(decimal: "1e-1000", bits: 3500)
  let b = a + epsilon
  #expect(b.double == a.double)
  #expect(abs((b-a).wide / epsilon.wide - 1) < 1e-14)
  #expect(abs((epsilon*epsilon).wide.double) == 0) // outside chosen fixed-point precision
  let scaled = WideReal(log2: -1000*log2(10))
  #expect(scaled.exponent < -3000)
  #expect(abs(scaled / epsilon.wide - 1) < 1e-12)
  #expect(throws: PrecisionError.self) { try DeepNumber(decimal: "nan", bits: 100) }
  #expect(throws: PrecisionError.self) { try DeepNumber(decimal: "1e999999", bits: 100) }
}
@Test func fixedPointSignsAndPrecision() {
  for value in [-2.0, -0.743643887037151, 0, 0.13182590390533, 2] {
    let a = DeepNumber(value, bits: 400)
    #expect(a.double == value)
    #expect(a.rounded(to: 4000).rounded(to: 400) == a)
    #expect(abs((a*a).double - value*value) < 1e-15)
  }
}
