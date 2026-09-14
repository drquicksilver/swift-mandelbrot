import Foundation

/// A depth-based starting estimate. Pixel-driven adaptation and periodicity
/// checking remain separate work; a capped sample is still unresolved.
enum IterationPolicy {
  static let maximum = 1_000_000
  static func estimate(logScale: Double, multiplier: Double = 1) -> Int {
    let target = (200 + 80 * max(0, logScale)) * multiplier
    return max(200, min(maximum, Int(ceil(min(Double(maximum), target) / 200)) * 200))
  }
  static func shouldLower(current: Int, target: Int) -> Bool {
    target < current && (target == 200 || current - target >= max(200, current / 10))
  }
  static func shouldRaise(current: Int, target: Int) -> Bool {
    target > current && (target == maximum || target - current >= max(200, current / 10))
  }
}
