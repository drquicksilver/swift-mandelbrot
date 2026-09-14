import CoreGraphics

/// One high-precision camera conversion per frame, relative to a nearby visible
/// tile. All same-anchor cell transforms then use integer-key arithmetic.
struct TileProjection {
  let origin: TileBounds
  let screenOrigin: CGPoint
  let pixelSpan: Double
  init(origin: TileBounds, viewport: Viewport, size: CGSize) {
    self.origin = origin
    screenOrigin = viewport.screen(for: origin.preciseOrigin, in: size)
    pixelSpan = origin.wideSpan / viewport.wideSpan * size.width
  }
  func center(of bounds: TileBounds) -> CGPoint {
    let r = bounds.relative(to: origin)
    return CGPoint(
      x: screenOrigin.x + (r.x + r.extent / 2) * pixelSpan,
      y: screenOrigin.y + (r.y + r.extent / 2) * pixelSpan)
  }
}
