import Foundation

enum RendererID: String, CaseIterable, Identifiable, Sendable {
    case baseline, scalarTight = "scalar-tight", coordPrecompute = "coord-precompute"
    case unsafeBuffer = "unsafe-buffer", floatMath = "float-math", parallel
    case simd4Float = "simd4-float", metal, metalDouble = "metal-double"
    var id: String { rawValue }
    var isGPU: Bool { self == .metal || self == .metalDouble }
    var usesFloat: Bool { [.floatMath, .simd4Float, .metal].contains(self) }
    var title: String {
        switch self {
        case .metal: return "GPU Float"
        case .metalDouble: return "GPU FloatFloat"
        case .parallel: return "CPU Double (parallel)"
        case .baseline: return "CPU Double"
        default: return rawValue
        }
    }
}
