import Foundation

struct TilePresentation {
  static let fadeDuration = 0.125
  static func fade(readyAt: Double, now: Double) -> Float {
    Float(min(1, max(0, (now - readyAt) / fadeDuration)))
  }
  static func fineWeight(lod: Double, readyAt: Double, now: Double) -> Float {
    Float(lod - floor(lod)) * fade(readyAt: readyAt, now: now)
  }
}
