import CoreGraphics
import Foundation

/// All navigation is expressed in logical view points; rendering supplies pixel width
/// separately so Retina and non-Retina displays share the same complex-plane view.
struct Viewport: Equatable, Sendable {
  var center = CGPoint(x: -0.5, y: 0)
  var scale = 1.0
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
    let fixedPoint = complex(at: CGPoint(x: rect.midX, y: rect.midY), in: size)
    let factor = min(size.width / max(1, rect.width), size.height / max(1, rect.height))
    zoom(
      by: factor, at: CGPoint(x: size.width / 2, y: size.height / 2), in: size,
      pixelWidth: pixelWidth)
    center = fixedPoint
  }
  func recommendedRenderer(pixelWidth: Double) -> RendererID {
    let spacing = span / max(1, pixelWidth)
    let floatULP = Double(max(Float(center.x).ulp, Float(center.y).ulp, Float(1).ulp))
    return spacing >= floatULP * 32 ? .metal : .metalDouble
  }
}
