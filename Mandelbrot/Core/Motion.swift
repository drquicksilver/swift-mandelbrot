import CoreGraphics
import Foundation

/// Integrates exponential decay analytically, making travel independent of refresh rate.
struct Motion: Sendable {
  var velocity = SIMD2<Double>.zero
  var zoomVelocity = 0.0  // logarithmic scale per second
  var rotationVelocity = 0.0  // radians per second
  var active: Bool {
    abs(velocity.x) + abs(velocity.y) > 3 || abs(zoomVelocity) > 0.005
      || abs(rotationVelocity) > 0.01
  }
  mutating func stop() {
    velocity = .zero
    zoomVelocity = 0
    rotationVelocity = 0
  }
  /// Springs and animations share this analytic approach: the fraction covered
  /// depends only on elapsed time, so a spring is frame-rate independent and
  /// combines with a fling.
  static func approach(from current: Double, to target: Double, rate: Double, seconds: Double)
    -> Double
  {
    current + (target - current) * (1 - exp(-rate * min(seconds, 0.05)))
  }
  mutating func step(seconds: Double) -> (pan: CGSize, zoom: Double, rotation: Double) {
    guard active, seconds > 0 else { return (.zero, 1, 0) }
    let dt = min(seconds, 0.05)
    let decay = exp(-7 * dt)
    let distance = (1 - decay) / 7
    let pan = CGSize(width: velocity.x * distance, height: velocity.y * distance)
    let zoom = exp(zoomVelocity * distance)
    let rotation = rotationVelocity * distance
    velocity *= decay
    zoomVelocity *= decay
    rotationVelocity *= decay
    if !active { stop() }
    return (pan, zoom, rotation)
  }
}
