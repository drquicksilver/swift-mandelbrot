import Foundation
import Testing

@testable import MandelbrotCore

@Test func inertiaIsRefreshRateIndependent() {
  func travel(hz: Int) -> (Double, Double) {
    var motion = Motion(velocity: SIMD2(1000, 0), zoomVelocity: 2)
    var x = 0.0
    var scale = 1.0
    for _ in 0..<(hz / 2) {
      let delta = motion.step(seconds: 1 / Double(hz))
      x += delta.pan.width
      scale *= delta.zoom
    }
    return (x, scale)
  }
  let a = travel(hz: 60)
  let b = travel(hz: 120)
  #expect(abs(a.0 - b.0) < 1e-9)
  #expect(abs(a.1 - b.1) < 1e-9)
}
@Test func inertiaStopsAndBoundsLongFrames() {
  var motion = Motion(velocity: SIMD2(1000, 1000), zoomVelocity: 1)
  let delta = motion.step(seconds: 20)
  #expect(delta.pan.width < 50)
  for _ in 0..<400 { _ = motion.step(seconds: 1 / 60) }
  #expect(!motion.active)
}
