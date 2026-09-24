import Foundation

enum RendererID: String, CaseIterable, Identifiable, Sendable {
  case baseline
  case scalarTight = "scalar-tight"
  case coordPrecompute = "coord-precompute"
  case unsafeBuffer = "unsafe-buffer"
  case floatMath = "float-math"
  case parallel
  case simd4Float = "simd4-float"
  case metal
  case metalDouble = "metal-double"
  case perturbation
  var id: String { rawValue }
  var isGPU: Bool { self == .metal || self == .metalDouble || self == .perturbation }
  var title: String {
    switch self {
    case .perturbation: return "GPU Perturbation"
    case .metal: return "GPU Float"
    case .metalDouble: return "GPU FloatFloat"
    case .parallel: return "CPU Double (parallel)"
    case .baseline: return "CPU Double"
    default: return rawValue
    }
  }
}
