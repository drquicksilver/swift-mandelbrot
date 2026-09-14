import CoreGraphics
import Foundation

struct TileKey: Hashable, Sendable {
  let level: Int
  let x: Int64
  let y: Int64
  let anchorID: UInt64
  var parent: TileKey { TileKey(level: level - 1, x: x >> 1, y: y >> 1, anchorID: anchorID) }
  var children: [TileKey] {
    [
      TileKey(level: level + 1, x: x * 2, y: y * 2, anchorID: anchorID),
      TileKey(level: level + 1, x: x * 2 + 1, y: y * 2, anchorID: anchorID),
      TileKey(level: level + 1, x: x * 2, y: y * 2 + 1, anchorID: anchorID),
      TileKey(level: level + 1, x: x * 2 + 1, y: y * 2 + 1, anchorID: anchorID),
    ]
  }
  func relative(to source: TileKey) -> (x: Double, y: Double, extent: Double) {
    precondition(anchorID == source.anchorID)
    let shift = level - source.level
    let extent = pow(2, -Double(shift))
    func coordinate(_ value: Int64, _ origin: Int64) -> Double {
      if shift >= 0 && shift < 62 {
        let whole = value >> shift
        let remainder = value - (whole << shift)
        return Double(whole - origin) + Double(remainder) * extent
      }
      return Double(value) * extent - Double(origin)
    }
    return (coordinate(x, source.x), coordinate(y, source.y), extent)
  }
  func ancestor(at level: Int) -> TileKey {
    let shift = self.level - level
    precondition(shift >= 0)
    return TileKey(level: level, x: x >> min(63, shift), y: y >> min(63, shift), anchorID: anchorID)
  }
}
struct TileBounds: Sendable {
  let left: Double, top: Double, span: Double
  var key: TileKey?
  var deepOrigin: DeepPoint?
  var deepLevel: Int?
  var wideSpan: WideReal { deepLevel.map { WideReal(3, exponent: -$0) } ?? WideReal(span) }
  var preciseOrigin: DeepPoint { deepOrigin ?? DeepPoint(CGPoint(x: left, y: top), bits: 192) }
  var preciseCenter: DeepPoint {
    preciseOrigin.offset(
      x: wideSpan * 0.5, y: wideSpan * -0.5, bits: max(192, (deepLevel ?? 0) + 128))
  }
  func relative(to source: TileBounds) -> (x: Double, y: Double, extent: Double) {
    if let key, let other = source.key, key.anchorID == other.anchorID {
      return key.relative(to: other)
    }
    if deepOrigin == nil && source.deepOrigin == nil {
      return (
        (left - source.left) / source.span, (source.top - top) / source.span, span / source.span
      )
    }
    return (
      (preciseOrigin.x - source.preciseOrigin.x).wide / source.wideSpan,
      (source.preciseOrigin.y - preciseOrigin.y).wide / source.wideSpan, wideSpan / source.wideSpan
    )
  }
  func intersects(viewport: Viewport, size: CGSize) -> Bool {
    let p = viewport.screen(for: preciseCenter, in: size)
    let radius = wideSpan / viewport.wideSpan * size.width / 2
    return p.x - radius < size.width && p.x + radius > 0 && p.y - radius < size.height
      && p.y + radius > 0
  }
  var center: CGPoint { CGPoint(x: left + span / 2, y: top - span / 2) }
}
struct TileGrid: Sendable {
  static let samples = 256
  static let gutter = 1
  static let textureSize = samples + 2 * gutter
  var anchor: CGPoint
  var anchorID: UInt64 = 0
  var deepAnchor: DeepPoint?
  func span(at level: Int) -> Double { 3 * pow(2, -Double(level)) }
  func bounds(_ key: TileKey) -> TileBounds {
    let span = span(at: key.level)
    if deepAnchor != nil || key.level > 30 {
      let wide = WideReal(3, exponent: -key.level)
      let origin = (deepAnchor ?? DeepPoint(anchor, bits: 192)).offset(
        x: wide * Double(key.x), y: wide * -Double(key.y), bits: max(192, key.level + 128))
      return TileBounds(
        left: origin.x.double, top: origin.y.double, span: span, key: key, deepOrigin: origin,
        deepLevel: key.level)
    }
    return TileBounds(
      left: anchor.x + Double(key.x) * span, top: anchor.y - Double(key.y) * span, span: span,
      key: key)
  }
  func idealLevel(viewport: Viewport, pixelWidth: Double) -> Double {
    viewport.logScale + log2(max(1, pixelWidth) / Double(Self.samples))
  }
  func visible(viewport: Viewport, size: CGSize, level: Int) -> [TileKey] {
    let minX: Double
    let maxX: Double
    let minY: Double
    let maxY: Double
    if deepAnchor != nil || viewport.deepCenter != nil || level > 30 {
      let wide = WideReal(3, exponent: -level)
      let anchor = deepAnchor ?? DeepPoint(self.anchor, bits: viewport.precisionBits)
      let c = viewport.preciseCenter
      let x = (c.x - anchor.x).wide / wide
      let y = (anchor.y - c.y).wide / wide
      let half = viewport.wideSpan / wide / 2
      let tall = half * size.height / max(1, size.width)
      minX = x - half
      maxX = x + half
      minY = y - tall
      maxY = y + tall
    } else {
      let span = span(at: level)
      let height = viewport.span * size.height / max(1, size.width)
      minX = (viewport.center.x - viewport.span / 2 - anchor.x) / span
      maxX = (viewport.center.x + viewport.span / 2 - anchor.x) / span
      minY = (anchor.y - (viewport.center.y + height / 2)) / span
      maxY = (anchor.y - (viewport.center.y - height / 2)) / span
    }
    guard [minX, maxX, minY, maxY].allSatisfy({ $0.isFinite && abs($0) < Double(Int64.max) / 4 })
    else { return [] }
    let x0 = Int64(floor(minX))
    let x1 = max(x0, Int64(ceil(maxX)) - 1)
    let y0 = Int64(floor(minY))
    let y1 = max(y0, Int64(ceil(maxY)) - 1)
    guard (x1 - x0 + 1) * (y1 - y0 + 1) <= 4096 else { return [] }
    return (y0...y1).flatMap { y in
      (x0...x1).map { TileKey(level: level, x: $0, y: y, anchorID: anchorID) }
    }
  }
  mutating func rebase(to point: DeepPoint) {
    anchor = point.point
    deepAnchor = point
    anchorID &+= 1
  }
  mutating func rebase(to anchor: CGPoint) {
    self.deepAnchor = nil
    self.anchor = anchor
    anchorID &+= 1
  }
}
