import CoreGraphics
import Foundation

/// All navigation is expressed in logical view points; rendering supplies pixel width
/// separately so Retina and non-Retina displays share the same complex-plane view.
struct Viewport: Equatable, Sendable {
  var center = CGPoint(x: -0.5, y: 0)
  var scale = 1.0
  /// Rotation of the complex plane relative to the screen, in radians.  Applied
  /// to Double offsets from the screen centre, so precision is unaffected at any
  /// depth, and tiles stay axis-aligned in the plane.
  var angle = 0.0
  // Deep storage becomes authoritative before Double camera arithmetic loses a pixel.
  var deepCenter: DeepPoint?
  var deepLogScale: Double?
  static let maximumLogScale = 13_000.0
  /// The scale at which the whole set fits the view, in both dimensions.  The
  /// view's width spans `3 / scale` of the plane, so width alone is satisfied at
  /// scale 1; the height then covers `3 / scale` times the aspect ratio, which
  /// has to reach the set's 2.4.  A window at least 0.8 as tall as it is wide
  /// rests at scale 1, and a wider one pulls back until the top and bottom of
  /// the set are on screen.
  static func restingLogScale(size: CGSize) -> Double {
    let aspect = max(1, size.height) / max(1, size.width)
    return min(0, log2(setBounds.width / setBounds.height * aspect))
  }
  /// The furthest zoom-out: the whole set with room around it.  Gentle bounds
  /// spring back from there to the resting scale, an octave in.
  static func minimumLogScale(size: CGSize) -> Double { restingLogScale(size: size) - 1 }
  /// The whole set, with a small margin.  Gentle bounds keep the view centre
  /// within this box, expanded by most of the view's half-extents, so part of
  /// the set always stays on screen.
  static let setBounds = CGRect(x: -2.2, y: -1.2, width: 3.0, height: 2.4)
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
  /// Screen offsets in units of the view's width, measured from the centre with
  /// y upwards, and the same offsets rotated into the complex plane.
  func viewOffset(of point: CGPoint, in size: CGSize) -> (x: Double, y: Double) {
    let width = max(1, size.width)
    return (point.x / width - 0.5, (size.height / 2 - point.y) / width)
  }
  func planeOffset(of point: CGPoint, in size: CGSize) -> (x: Double, y: Double) {
    let view = viewOffset(of: point, in: size)
    return (
      cos(angle) * view.x - sin(angle) * view.y, sin(angle) * view.x + cos(angle) * view.y
    )
  }
  private func screenPoint(fromPlane x: Double, _ y: Double, in size: CGSize) -> CGPoint {
    let view = (x: cos(angle) * x + sin(angle) * y, y: -sin(angle) * x + cos(angle) * y)
    return CGPoint(
      x: (view.x + 0.5) * size.width, y: size.height / 2 - view.y * size.width)
  }
  func preciseComplex(at point: CGPoint, in size: CGSize) -> DeepPoint {
    let offset = planeOffset(of: point, in: size)
    return preciseCenter.offset(
      x: wideSpan * offset.x, y: wideSpan * offset.y, bits: precisionBits)
  }
  func screen(for point: DeepPoint, in size: CGSize) -> CGPoint {
    let c = preciseCenter
    return screenPoint(
      fromPlane: (point.x - c.x).wide / wideSpan, (point.y - c.y).wide / wideSpan, in: size)
  }
  var span: Double { 3 / scale }

  func complex(at point: CGPoint, in size: CGSize) -> CGPoint {
    let offset = planeOffset(of: point, in: size)
    return CGPoint(x: center.x + offset.x * span, y: center.y + offset.y * span)
  }
  func screen(for point: CGPoint, in size: CGSize) -> CGPoint {
    screenPoint(
      fromPlane: (point.x - center.x) / span, (point.y - center.y) / span, in: size)
  }
  mutating func pan(by delta: CGSize, in size: CGSize) {
    let width = max(1, size.width)
    let view = (x: -delta.width / width, y: delta.height / width)
    let offset = (
      x: cos(angle) * view.x - sin(angle) * view.y, y: sin(angle) * view.x + cos(angle) * view.y
    )
    if deepCenter != nil {
      deepCenter = preciseCenter.offset(
        x: wideSpan * offset.x, y: wideSpan * offset.y, bits: precisionBits)
      center = deepCenter!.point
      return
    }
    center.x += offset.x * span
    center.y += offset.y * span
  }
  /// Rotates about a screen point, keeping the plane point under it fixed.
  mutating func rotate(by delta: Double, at anchor: CGPoint, in size: CGSize) {
    guard delta.isFinite, delta != 0 else { return }
    let fixed = preciseComplex(at: anchor, in: size)
    angle = Self.normalised(angle + delta)
    let offset = planeOffset(of: anchor, in: size)
    let moved = fixed.offset(
      x: wideSpan * -offset.x, y: wideSpan * -offset.y, bits: precisionBits)
    if deepCenter != nil { deepCenter = moved }
    center = moved.point
  }
  /// Keeps the angle in (-pi, pi], so sharing and comparison are canonical.
  static func normalised(_ angle: Double) -> Double {
    let turn = 2 * Double.pi
    let wrapped = angle.truncatingRemainder(dividingBy: turn)
    return wrapped > Double.pi ? wrapped - turn : (wrapped <= -Double.pi ? wrapped + turn : wrapped)
  }
  /// Half-extents of the rotated view's bounding box, in units of view width.
  /// Covering the box needs about 2.2x the tiles of an unrotated 16:9 screen at 45.
  func coverage(size: CGSize) -> (x: Double, y: Double) {
    let aspect = max(1, size.height) / max(1, size.width)
    let c = abs(cos(angle)), s = abs(sin(angle))
    return ((c + s * aspect) / 2, (s + c * aspect) / 2)
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
      deepLogScale = min(
        Self.maximumLogScale, max(Self.minimumLogScale(size: size), wantedLog))
      // The offset back from the anchor to the centre is a plane offset, so it
      // carries the rotation; an unrotated one walks the centre off sideways.
      let offset = planeOffset(of: anchor, in: size)
      deepCenter = fixed.offset(
        x: wideSpan * -offset.x, y: wideSpan * -offset.y, bits: precisionBits)
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
    scale = min(limit, max(pow(2, Self.minimumLogScale(size: size)), wanted))
    let movedPoint = complex(at: anchor, in: size)
    center.x += fixedPoint.x - movedPoint.x
    center.y += fixedPoint.y - movedPoint.y
    return wanted >= limit
  }
  /// Zooms to a screen rectangle; the rectangle is axis-aligned on screen, so a
  /// rotated view keeps its angle and re-centres on the rectangle's middle.
  mutating func fit(_ rect: CGRect, in size: CGSize, pixelWidth: Double) {
    let fixedPoint = preciseComplex(at: CGPoint(x: rect.midX, y: rect.midY), in: size)
    let factor = min(size.width / max(1, rect.width), size.height / max(1, rect.height))
    zoom(
      by: factor, at: CGPoint(x: size.width / 2, y: size.height / 2), in: size,
      pixelWidth: pixelWidth)
    center = fixedPoint.point
    if deepCenter != nil { deepCenter = fixedPoint }
  }
  /// The nearest centre that keeps part of the set on screen.
  func boundedCenter(size: CGSize) -> CGPoint {
    let coverage = coverage(size: size)
    let margin = 0.9
    let hx = span * coverage.x * margin, hy = span * coverage.y * margin
    return CGPoint(
      x: min(max(center.x, Self.setBounds.minX - hx), Self.setBounds.maxX + hx),
      y: min(max(center.y, Self.setBounds.minY - hy), Self.setBounds.maxY + hy))
  }
  func recommendedRenderer(pixelWidth: Double) -> RendererID {
    PrecisionPolicy.renderer(logScale: logScale, pixelWidth: pixelWidth, center: center)
  }
}
