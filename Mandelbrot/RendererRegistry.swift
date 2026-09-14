import CoreGraphics

struct RenderRequest {
    var width: Int
    var height: Int
    var viewport: Viewport
    var blockSize = 1
    var configuration = MandelbrotConfiguration()
}

protocol Renderer {
    var id: RendererID { get }
    func iterations(_ request: RenderRequest) -> MandelbrotIterations?
}

private struct RegisteredRenderer: Renderer {
    let id: RendererID
    let render: (RenderRequest) -> MandelbrotIterations?
    func iterations(_ request: RenderRequest) -> MandelbrotIterations? { render(request) }
}

enum RendererRegistry {
    private typealias CPUFunction = (Int, Int, CGPoint, Double, Int, MandelbrotConfiguration) -> MandelbrotIterations
    static func renderer(for id: RendererID) -> any Renderer {
        let cpu: CPUFunction?
        switch id {
        case .baseline: cpu = MandelbrotRenderer.iterations
        case .scalarTight: cpu = MandelbrotRenderer.iterationsScalarTightened
        case .coordPrecompute: cpu = MandelbrotRenderer.iterationsCoordPrecompute
        case .unsafeBuffer: cpu = MandelbrotRenderer.iterationsUnsafeBuffer
        case .floatMath: cpu = MandelbrotRenderer.iterationsFloatMath
        case .parallel: cpu = MandelbrotRenderer.iterationsParallel
        case .simd4Float: cpu = MandelbrotRenderer.iterationsSIMD4Float
        case .metal, .metalDouble: cpu = nil
        }
        return RegisteredRenderer(id: id) { request in
            if let cpu { return cpu(request.width, request.height, request.viewport.center,
                request.viewport.scale, request.blockSize, request.configuration) }
            let render = id == .metal ? MandelbrotMetalRenderer.iterations : MandelbrotMetalRenderer.iterationsDouble
            return render(request.width, request.height, request.viewport.center, request.viewport.scale, request.configuration)
        }
    }
}
