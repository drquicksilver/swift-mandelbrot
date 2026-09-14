import CoreGraphics
import Foundation

/// Integrates exponential decay analytically, making travel independent of refresh rate.
struct Motion: Sendable {
  var velocity = SIMD2<Double>.zero
  var zoomVelocity = 0.0  // logarithmic scale per second
  var active: Bool { abs(velocity.x) + abs(velocity.y) > 3 || abs(zoomVelocity) > 0.005 }
  mutating func stop() {
    velocity = .zero
    zoomVelocity = 0
  }
  mutating func step(seconds: Double) -> (pan: CGSize, zoom: Double) {
    guard active, seconds > 0 else { return (.zero, 1) }
    let dt = min(seconds, 0.05)
    let decay = exp(-7 * dt)
    let distance = (1 - decay) / 7
    let pan = CGSize(width: velocity.x * distance, height: velocity.y * distance)
    let zoom = exp(zoomVelocity * distance)
    velocity *= decay
    zoomVelocity *= decay
    if !active { stop() }
    return (pan, zoom)
  }
}
