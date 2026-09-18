import CoreGraphics

/// One high-precision camera conversion per frame, relative to a nearby visible
/// tile. All same-anchor cell transforms then use integer-key arithmetic.
struct TileProjection {
  let origin: TileBounds
  let screenOrigin: CGPoint
  let pixelSpan: Double
  /// Tile offsets are axis-aligned in the plane; on screen they rotate with the
  /// view, as x-right/y-down offsets turned by the viewport's angle.
  let cosAngle: Double, sinAngle: Double
  init(origin: TileBounds, viewport: Viewport, size: CGSize) {
    self.origin = origin
    screenOrigin = viewport.screen(for: origin.preciseOrigin, in: size)
    pixelSpan = origin.wideSpan / viewport.wideSpan * size.width
    cosAngle = cos(viewport.angle)
    sinAngle = sin(viewport.angle)
  }
  func center(of bounds: TileBounds) -> CGPoint {
    let r = bounds.relative(to: origin)
    let dx = (r.x + r.extent / 2) * pixelSpan
    let dy = (r.y + r.extent / 2) * pixelSpan
    return CGPoint(
      x: screenOrigin.x + dx * cosAngle - dy * sinAngle,
      y: screenOrigin.y + dx * sinAngle + dy * cosAngle)
  }
}
