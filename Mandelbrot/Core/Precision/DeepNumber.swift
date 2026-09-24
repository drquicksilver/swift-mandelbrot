import CoreGraphics
import Foundation

/// Binary fixed point for camera coordinates and CPU reference orbits. Precision is
/// local to each value; increasing it preserves all existing bits. BigInt is MIT licensed.
struct DeepNumber: Equatable, Sendable {
  var raw: BigInt
  var bits: Int
  init(raw: BigInt, bits: Int) {
    self.raw = raw
    self.bits = bits
  }
  init(_ value: Double, bits: Int) {
    precondition(value.isFinite)
    self.bits = bits
    if value == 0 {
      raw = 0
      return
    }
    let exponent = value.exponent
    raw = BigInt((value.sign == .minus ? -1 : 1) * value.significand * pow(2, 52))
    raw = raw << (bits + exponent - 52)
  }
  init(decimal: String, bits: Int) throws {
    let parts = decimal.lowercased().split(separator: "e", omittingEmptySubsequences: false)
    guard parts.count <= 2, let exponent = parts.count == 2 ? Int(parts[1]) : 0,
      (-5000...5000).contains(exponent)
    else { throw PrecisionError("Invalid decimal exponent") }
    let mantissa = String(parts[0])
    let fraction = mantissa.split(separator: ".", omittingEmptySubsequences: false)
    guard fraction.count <= 2, mantissa.count <= 5100,
      let integer = BigInt(mantissa.replacingOccurrences(of: ".", with: ""))
    else {
      throw PrecisionError("Invalid decimal coordinate")
    }
    let places = (fraction.count == 2 ? fraction[1].count : 0) - exponent
    self.bits = bits
    if places >= 0 {
      raw = (integer << bits) / BigInt(10).power(places)
    } else {
      raw = (integer * BigInt(10).power(-places)) << bits
    }
  }
  // Sign-and-magnitude right shifts truncate toward zero, including negatives;
  // coordinate/reference calculations retain 128 guard bits.
  func rounded(to bits: Int) -> Self { Self(raw: raw << (bits - self.bits), bits: bits) }
  static func + (a: Self, b: Self) -> Self {
    let bits = max(a.bits, b.bits)
    return Self(raw: a.rounded(to: bits).raw + b.rounded(to: bits).raw, bits: bits)
  }
  static func - (a: Self, b: Self) -> Self {
    let bits = max(a.bits, b.bits)
    return Self(raw: a.rounded(to: bits).raw - b.rounded(to: bits).raw, bits: bits)
  }
  static func * (a: Self, b: Self) -> Self {
    let bits = max(a.bits, b.bits)
    return Self(raw: (a.raw * b.raw) << (bits - a.bits - b.bits), bits: bits)
  }
  var wide: WideReal {
    if raw == 0 { return WideReal(0) }
    let magnitude = raw.magnitude
    let shift = max(0, magnitude.bitWidth - 53)
    var leading = UInt64(magnitude >> shift)
    if shift > 0 {
      let remainder = magnitude - ((magnitude >> shift) << shift)
      let half = BigUInt(1) << (shift - 1)
      if remainder > half || (remainder == half && leading & 1 == 1) { leading += 1 }
    }
    return WideReal((raw.sign == .minus ? -1 : 1) * Double(leading), exponent: shift - bits)
  }
  /// Enough decimal digits to round-trip at the current working precision.
  var decimalString: String {
    if raw == 0 { return "0" }
    let digits = Int(ceil(Double(bits) * log10(2))) + 2
    let scaled = (raw.magnitude * BigUInt(10).power(digits)) >> bits
    var text = String(scaled)
    if text.count <= digits { text = String(repeating: "0", count: digits + 1 - text.count) + text }
    let split = text.index(text.endIndex, offsetBy: -digits)
    text.insert(".", at: split)
    while text.last == "0" { text.removeLast() }
    if text.last == "." { text.removeLast() }
    return (raw.sign == .minus ? "-" : "") + text
  }
  var double: Double { wide.double }
}
struct PrecisionError: Error, CustomStringConvertible, LocalizedError {
  let description: String
  init(_ description: String) { self.description = description }
  var errorDescription: String? { description }
}

/// Normalized mantissa and base-two exponent. Never materialize a deep span as Double.
struct WideReal: Equatable, Sendable {
  var mantissa: Double
  var exponent: Int
  init(_ value: Double, exponent: Int = 0) {
    precondition(value.isFinite)
    if value == 0 {
      mantissa = 0
      self.exponent = 0
    } else {
      mantissa = (value.sign == .minus ? -1 : 1) * value.significand
      self.exponent = exponent + value.exponent
    }
  }
  init(log2: Double) {
    let exponent = Int(floor(log2))
    self.init(pow(2, log2 - Double(exponent)), exponent: exponent)
  }
  var double: Double { Double(sign: mantissa.sign, exponent: exponent, significand: abs(mantissa)) }
  func fixed(bits: Int) -> DeepNumber {
    DeepNumber(raw: BigInt(mantissa * pow(2, 52)) << (exponent + bits - 52), bits: bits)
  }
  static func * (a: Self, b: Double) -> Self { Self(a.mantissa * b, exponent: a.exponent) }
  static func / (a: Self, b: Self) -> Double {
    Self(a.mantissa / b.mantissa, exponent: a.exponent - b.exponent).double
  }
}
struct DeepPoint: Equatable, Sendable {
  var x: DeepNumber, y: DeepNumber
  init(_ point: CGPoint, bits: Int) {
    x = DeepNumber(point.x, bits: bits)
    y = DeepNumber(point.y, bits: bits)
  }
  init(x: DeepNumber, y: DeepNumber) {
    self.x = x
    self.y = y
  }
  func offset(x: WideReal, y: WideReal, bits: Int) -> Self {
    Self(
      x: self.x.rounded(to: bits) + x.fixed(bits: bits),
      y: self.y.rounded(to: bits) + y.fixed(bits: bits))
  }
  var point: CGPoint { CGPoint(x: x.double, y: y.double) }
}
