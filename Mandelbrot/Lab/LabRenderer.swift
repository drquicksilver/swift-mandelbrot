// The lab renderers' dispatcher.  Their code lives in Core/Lab (the CPU
// variants) and MandelbrotMetalRenderer.swift (the first Metal kernels).

import CoreGraphics

/// Runs one of the lab renderers -- the CPU experiments and the first,
/// full-frame Metal kernels -- for the command line and the in-app benchmark.
/// They are measured against each other and against the golden fixtures, and
/// never draw the viewer.  An actor, so a long CPU render stays off the main
/// actor and two never compete for the cores.
actor LabRenderer {
  static let shared = LabRenderer()

  /// Escape counts, or nil when the renderer has no full-frame lab path
  /// (perturbation) or its Metal kernel could not run.
  func iterations(
    _ id: RendererID, width: Int, height: Int, center: CGPoint, scale: Double,
    configuration: MandelbrotConfiguration
  ) -> MandelbrotIterations? {
    let cpu: (Int, Int, CGPoint, Double, MandelbrotConfiguration) -> MandelbrotIterations
    switch id {
    case .baseline: cpu = MandelbrotRenderer.iterations
    case .scalarTight: cpu = MandelbrotRenderer.iterationsScalarTightened
    case .coordPrecompute: cpu = MandelbrotRenderer.iterationsCoordPrecompute
    case .unsafeBuffer: cpu = MandelbrotRenderer.iterationsUnsafeBuffer
    case .floatMath: cpu = MandelbrotRenderer.iterationsFloatMath
    case .parallel: cpu = MandelbrotRenderer.iterationsParallel
    case .simd4Float: cpu = MandelbrotRenderer.iterationsSIMD4Float
    case .metal:
      return MandelbrotMetalRenderer.iterations(
        width: width, height: height, center: center, scale: scale, configuration: configuration)
    case .metalDouble:
      return MandelbrotMetalRenderer.iterationsDouble(
        width: width, height: height, center: center, scale: scale, configuration: configuration)
    case .perturbation: return nil
    }
    return cpu(width, height, center, scale, configuration)
  }

  /// The counts in the original escape-time colouring, as `--pipeline legacy`
  /// writes them.
  func image(
    _ id: RendererID, width: Int, height: Int, center: CGPoint, scale: Double,
    configuration: MandelbrotConfiguration
  ) -> CGImage? {
    iterations(
      id, width: width, height: height, center: center, scale: scale,
      configuration: configuration
    ).flatMap { MandelbrotColorizer.image(from: $0) }
  }
}
