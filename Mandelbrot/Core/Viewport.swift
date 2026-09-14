import CoreGraphics
import Foundation

/// All navigation is expressed in logical view points; rendering supplies pixel width
/// separately so Retina and non-Retina displays share the same complex-plane view.
struct Viewport: Equatable, Sendable {
  var center = CGPoint(x: -0.5, y: 0)
  var scale = 1.0
  // Deep storage becomes authoritative before Double camera arithmetic loses a pixel.
  var deepCenter: DeepPoint?
  var deepLogScale: Double?
  static let maximumLogScale = 13_000.0
  var logScale: Double { deepLogScale ?? log2(scale) }
  var wideSpan: WideReal { WideReal(log2: log2(3) - logScale) }
  var precisionBits: Int { max(192, Int(ceil(logScale)) + 128) }
  var preciseCenter: DeepPoint { deepCenter ?? DeepPoint(center, bits: precisionBits) }
  var scaleDescription: String {
    guard deepLogScale != nil else { return String(scale) }
    let decimal = logScale / log2(10)
    let exponent = Int(floor(decimal))
    return String(format: "%.17ge%d", pow(10, decimal - Double(exponent)), exponent)
  }
  var centerDescription: String {
    guard let deepCenter else { return "\(center.x), \(center.y)" }
    return "\(deepCenter.x.decimalString), \(deepCenter.y.decimalString)"
  }
  init(center: CGPoint = CGPoint(x: -0.5, y: 0), scale: Double = 1) {
    self.center = center
    self.scale = scale
  }
  init(real: String, imag: String, zoom: String) throws {
    let parts = zoom.lowercased().split(separator: "e", omittingEmptySubsequences: false)
    guard parts.count <= 2, let m = Double(parts[0]), m > 0, m.isFinite,
      let e = parts.count == 2 ? Double(parts[1]) : 0, e.isFinite
    else {
      throw PrecisionError("Invalid scale")
    }
    let depth = log2(m) + e * log2(10)
    guard depth >= log2(1e-6), depth <= Self.maximumLogScale else {
      throw PrecisionError("Scale outside [1e-6, 2^13000]")
    }
    self.init(center: .zero, scale: Double(zoom).flatMap { $0.isFinite ? $0 : nil } ?? pow(2, 1023))
    let bits = max(192, Int(ceil(depth)) + 128)
    let point = try DeepPoint(
      x: DeepNumber(decimal: real, bits: bits), y: DeepNumber(decimal: imag, bits: bits))
    guard abs(point.x.double) <= 4, abs(point.y.double) <= 4 else {
      throw PrecisionError("Center outside [-4,4]")
    }
    center = point.point
    if depth > 30 {
      deepCenter = point
      deepLogScale = depth
    }
  }
  func preciseComplex(at point: CGPoint, in size: CGSize) -> DeepPoint {
    preciseCenter.offset(
      x: wideSpan * (point.x / max(1, size.width) - 0.5),
      y: wideSpan * ((size.height / 2 - point.y) / max(1, size.width)), bits: precisionBits)
  }
  func screen(for point: DeepPoint, in size: CGSize) -> CGPoint {
    let c = preciseCenter
    return CGPoint(
      x: ((point.x - c.x).wide / wideSpan + 0.5) * size.width,
      y: size.height / 2 - (point.y - c.y).wide / wideSpan * size.width)
  }
  var span: Double { 3 / scale }

  func complex(at point: CGPoint, in size: CGSize) -> CGPoint {
    let width = max(1, size.width)
    return CGPoint(
      x: center.x + (point.x / width - 0.5) * span,
      y: center.y + (size.height / 2 - point.y) / width * span)
  }
  func screen(for point: CGPoint, in size: CGSize) -> CGPoint {
    CGPoint(
      x: ((point.x - center.x) / span + 0.5) * size.width,
      y: size.height / 2 - (point.y - center.y) / span * size.width)
  }
  mutating func pan(by delta: CGSize, in size: CGSize) {
    if deepCenter != nil {
      deepCenter = preciseCenter.offset(
        x: wideSpan * (-delta.width / max(1, size.width)),
        y: wideSpan * (delta.height / max(1, size.width)), bits: precisionBits)
      center = deepCenter!.point
      return
    }
    center.x -= delta.width / max(1, size.width) * span
    center.y += delta.height / max(1, size.width) * span
  }
  func maximumScale(pixelWidth: Double) -> Double {
    // Eight FloatFloat ulps per pixel, including headroom for navigation math.
    let magnitude = max(1, abs(center.x), abs(center.y))
    return 3 / (max(1, pixelWidth) * magnitude * pow(2, -46) * 8)
  }
  @discardableResult mutating func zoom(
    by factor: Double, at anchor: CGPoint,
    in size: CGSize, pixelWidth: Double
  ) -> Bool {
    guard factor.isFinite, factor > 0 else { return false }
    let wantedLog = logScale + log2(factor)
    if deepCenter != nil || wantedLog > 30 {
      let fixed = preciseComplex(at: anchor, in: size)
      deepLogScale = min(Self.maximumLogScale, max(-1, wantedLog))
      deepCenter = fixed.offset(
        x: wideSpan * (0.5 - anchor.x / max(1, size.width)),
        y: wideSpan * ((anchor.y - size.height / 2) / max(1, size.width)), bits: precisionBits)
      center = deepCenter!.point
      scale = pow(2, min(logScale, 1023))
      if logScale < 28 {
        deepCenter = nil
        deepLogScale = nil
      }
      return wantedLog >= Self.maximumLogScale
    }
    let fixedPoint = complex(at: anchor, in: size)
    let limit = maximumScale(pixelWidth: pixelWidth)
    let wanted = scale * factor
    scale = min(limit, max(0.5, wanted))
    let movedPoint = complex(at: anchor, in: size)
    center.x += fixedPoint.x - movedPoint.x
    center.y += fixedPoint.y - movedPoint.y
    return wanted >= limit
  }
  mutating func fit(_ rect: CGRect, in size: CGSize, pixelWidth: Double) {
    let fixedPoint = preciseComplex(at: CGPoint(x: rect.midX, y: rect.midY), in: size)
    let factor = min(size.width / max(1, rect.width), size.height / max(1, rect.height))
    zoom(
      by: factor, at: CGPoint(x: size.width / 2, y: size.height / 2), in: size,
      pixelWidth: pixelWidth)
    center = fixedPoint.point
    if deepCenter != nil { deepCenter = fixedPoint }
  }
  func recommendedRenderer(pixelWidth: Double) -> RendererID {
    PrecisionPolicy.renderer(logScale: logScale, pixelWidth: pixelWidth, center: center)
  }
}
