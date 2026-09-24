// The timing of new detail: how far a refinement has faded in, and the weight
// of the finer level at a fractional level of detail.

import Foundation

struct TilePresentation {
  static let fadeDuration = 0.125
  /// A zero duration is an instant switch, for Reduce Motion.
  static func fade(readyAt: Double, now: Double, duration: Double = fadeDuration) -> Float {
    guard duration > 0 else { return now >= readyAt ? 1 : 0 }
    return Float(min(1, max(0, (now - readyAt) / duration)))
  }
  static func fineWeight(
    lod: Double, readyAt: Double, now: Double, duration: Double = fadeDuration
  ) -> Float {
    Float(lod - floor(lod)) * fade(readyAt: readyAt, now: now, duration: duration)
  }
}
