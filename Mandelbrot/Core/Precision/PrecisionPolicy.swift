// The precision ladder: which renderer a view needs -- Float, FloatFloat or
// perturbation -- from how many coordinate bits one pixel takes.

import CoreGraphics
import Foundation

/// Shared product precision policy, expressed in coordinate bits per pixel.
/// Laboratory CLI overrides remain explicit experiments at the user's chosen depth.
enum PrecisionPolicy {
  static let automaticBits = 40.0
  static let overrideBits = 48.0
  static func renderer(
    logScale: Double, pixelWidth: Double, center: CGPoint, override: RendererID? = nil
  ) -> RendererID {
    let bits = logScale + log2(max(1, pixelWidth))
    if bits > overrideBits { return .perturbation }
    if let override { return override }
    if bits > automaticBits { return .perturbation }
    let spacing = 3 * pow(2, -bits)
    let ulp = Double(max(Float(center.x).ulp, Float(center.y).ulp, Float(1).ulp))
    return spacing >= ulp * 32 ? .metal : .metalDouble
  }
}
