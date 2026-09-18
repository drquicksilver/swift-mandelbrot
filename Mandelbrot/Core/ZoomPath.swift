import CoreGraphics
import Foundation

/// The geometry of a zoom movie: a chain of keyframes one zoom level apart,
/// and the view at any moment between them.
///
/// The centre travels so that the destination holds its place on screen: the
/// offset from the end centre shrinks in proportion to the span, which is what
/// makes an exponential zoom look still.
struct ZoomPath: Sendable {
  let start: Location
  let end: Location
  let startLog: Double
  let endLog: Double
  let startCentre: DeepPoint
  let endCentre: DeepPoint
  let startAngle: Double
  let endAngle: Double
  /// Integer zoom levels from the start to the end, inclusive of both ends.
  let keyframeLevels: [Double]
  let eased: Bool

  init(start: Location, end: Location, eased: Bool = true) throws {
    let from = try start.viewport(), to = try end.viewport()
    guard to.logScale > from.logScale + 0.5 else {
      throw PrecisionError("A zoom movie needs at least half a zoom level of travel")
    }
    self.start = start
    self.end = end
    self.eased = eased
    startLog = from.logScale
    endLog = to.logScale
    startAngle = from.angle
    endAngle = to.angle
    let bits = max(from.precisionBits, to.precisionBits)
    startCentre = DeepPoint(
      x: from.preciseCenter.x.rounded(to: bits), y: from.preciseCenter.y.rounded(to: bits))
    endCentre = DeepPoint(
      x: to.preciseCenter.x.rounded(to: bits), y: to.preciseCenter.y.rounded(to: bits))
    var levels = stride(from: startLog, through: endLog, by: 1).map { $0 }
    if let last = levels.last, endLog - last > 1e-9 { levels.append(endLog) }
    keyframeLevels = levels
  }
  /// Smooth ease in and out, so the movie starts and stops gently.
  static func ease(_ t: Double) -> Double {
    let clamped = min(1, max(0, t))
    return clamped * clamped * (3 - 2 * clamped)
  }
  /// The zoom level at a moment in [0, 1].
  func level(at time: Double) -> Double {
    let t = eased ? Self.ease(time) : min(1, max(0, time))
    return startLog + (endLog - startLog) * t
  }
  func angle(at level: Double) -> Double {
    let span = endLog - startLog
    let t = span > 0 ? (level - startLog) / span : 1
    return Viewport.normalised(startAngle + Viewport.normalised(endAngle - startAngle) * t)
  }
  /// The centre at a zoom level.  The offset from the destination shrinks in
  /// proportion to the span, so the destination barely drifts while everything
  /// else flows outward, and the fraction is normalised so the first frame is
  /// exactly the start view and the last is exactly the end view.
  func centre(at level: Double) -> DeepPoint {
    let bits = max(startCentre.x.bits, endCentre.x.bits)
    // Two parts: the offset shrinks with the span, which is what makes the zoom
    // look still, and the remainder is drawn down linearly across the movie, so
    // the destination reaches the centre by the end instead of lurching there.
    let span = endLog - startLog
    let progress = span > 0 ? min(1, max(0, (level - startLog) / span)) : 1
    let fraction = WideReal(log2: startLog - level) * (1 - progress)
    return endCentre.offset(
      x: (startCentre.x - endCentre.x).wide * fraction,
      y: (startCentre.y - endCentre.y).wide * fraction, bits: bits)
  }
  func viewport(at level: Double) throws -> Viewport {
    var view = try Location(
      viewport: Viewport(), iterations: nil
    ).viewport()
    let centre = centre(at: level)
    view = Viewport(center: centre.point, scale: pow(2, min(level, 1023)))
    if level > 30 {
      view.deepCenter = centre
      view.deepLogScale = level
    }
    view.angle = angle(at: level)
    return view
  }
  /// The iteration limit for a keyframe: the movie honours an explicit limit at
  /// the destination and otherwise follows the automatic depth estimate.
  ///
  /// Bounding this by what an earlier keyframe observed, as the viewer's ceiling
  /// does, was measured and removed: see Performance.md 2.8.  Where the estimate
  /// overshoots it gave back 59% of the summed limit for about 6% of the time,
  /// and on a descent into a minibrot -- the slow case -- it never engaged at
  /// all, because such a view always holds counts close to its limit.
  func iterations(at level: Double) -> Int {
    if let limit = end.iterations { return limit }
    return IterationPolicy.estimate(logScale: level)
  }
  /// Palette offset for a keyframe when cycling: the phase advances with depth,
  /// which is what keeps a long zoom from looking monotonous.
  func paletteOffset(at level: Double, cycles: Double) -> Double {
    guard cycles != 0, endLog > startLog else { return end.offset }
    return end.offset + cycles * (level - startLog) / (endLog - startLog)
  }
}
