// Arithmetic and comparison for `WideReal`, and `WideComplex`, as the BLA
// construction needs them without ever leaving the extended exponent range.

import Foundation

extension WideReal: Comparable {
  static func < (a: Self, b: Self) -> Bool {
    if a.mantissa == 0 || b.mantissa == 0 || (a.mantissa < 0) != (b.mantissa < 0) {
      return a.mantissa < b.mantissa
    }
    if a.exponent == b.exponent { return a.mantissa < b.mantissa }
    return a.mantissa > 0 ? a.exponent < b.exponent : a.exponent > b.exponent
  }
  static prefix func - (a: Self) -> Self { Self(-a.mantissa, exponent: a.exponent) }
  static func + (a: Self, b: Self) -> Self {
    if a.mantissa == 0 { return b }
    if b.mantissa == 0 { return a }
    if a.exponent < b.exponent { return b + a }
    let shift = b.exponent - a.exponent
    if shift < -60 { return a }
    return Self(
      a.mantissa + Double(sign: b.mantissa.sign, exponent: shift, significand: abs(b.mantissa)),
      exponent: a.exponent)
  }
  static func - (a: Self, b: Self) -> Self { a + (-b) }
  static func * (a: Self, b: Self) -> Self {
    Self(a.mantissa * b.mantissa, exponent: a.exponent + b.exponent)
  }
  func divided(by b: Self) -> Self {
    precondition(b.mantissa != 0)
    return Self(mantissa / b.mantissa, exponent: exponent - b.exponent)
  }
  var magnitude: Self { Self(abs(mantissa), exponent: exponent) }
}
struct WideComplex: Sendable {
  var x, y: WideReal
  init(_ x: Double, _ y: Double) {
    self.x = WideReal(x)
    self.y = WideReal(y)
  }
  init(x: WideReal, y: WideReal) {
    self.x = x
    self.y = y
  }
  static func + (a: Self, b: Self) -> Self { Self(x: a.x + b.x, y: a.y + b.y) }
  static func * (a: Self, b: Self) -> Self {
    Self(x: a.x * b.x - a.y * b.y, y: a.x * b.y + a.y * b.x)
  }
  var magnitude: WideReal {
    if x.mantissa == 0 { return y.magnitude }
    if y.mantissa == 0 { return x.magnitude }
    let exponent = max(x.exponent, y.exponent)
    return WideReal(
      hypot(
        WideReal(x.mantissa, exponent: x.exponent - exponent).double,
        WideReal(y.mantissa, exponent: y.exponent - exponent).double), exponent: exponent)
  }
  var packed: ExtendedComplex { ExtendedComplex(x: ExtendedFloat(x), y: ExtendedFloat(y)) }
}
