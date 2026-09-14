import Combine
import SwiftUI

@MainActor final class ExplorerModel: ObservableObject {
    @Published var colouring = ColourSettings() { didSet { recolour() } }
    private var colourTask: Task<Void, Never>?
    func recolour() {
        colourTask?.cancel()
        guard let frame = gpuFrame, let gpu = GPUContext.shared else { return }
        let settings = colouring
        colourTask = Task {
            do {
                let texture = try gpu.texture(width:frame.samples.width,height:frame.samples.height,format:.rgba8Unorm)
                let time = try await gpu.colour(frame.samples,into:texture,settings:settings)
                try Task.checkCancellation()
                guard self.gpuFrame?.samples === frame.samples else { return }
                self.gpuFrame = GPUFrame(samples:frame.samples,colour:texture,kernelSeconds:frame.kernelSeconds,colourSeconds:time)
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    @Published var viewport = Viewport() { didSet { if viewport != oldValue { requestRender() } } }
    @Published var iterations = 200 { didSet { requestRender() } }
    @Published var rendererOverride: RendererID? { didSet { requestRender() } }
    @Published var image: CGImage?
    @Published var gpuFrame: GPUFrame?
    private var gpuBusy = false
    @Published var imageViewport = Viewport()
    @Published var duration = 0.0
    @Published var progress = 0.0
    @Published var error: String?
    @Published var showHelp = false
    @Published var showBenchmark = false
    @Published var showSettings = false
    @Published var showDeveloper = false
    @Published var showHUD = false
    @Published var showTileOverlay = false
    @Published var atPrecisionLimit = false
    var size = CGSize(width: 900, height: 600)
    var displayScale = 1.0
    private var renderTask: Task<Void, Never>?
    var pixelWidth: Double { size.width * displayScale }
    var renderer: RendererID { rendererOverride ?? viewport.recommendedRenderer(pixelWidth: pixelWidth) }

    func resize(_ size: CGSize, displayScale: Double) {
        guard size.width > 0, size.height > 0 else { return }
        self.size = size
        self.displayScale = displayScale
        viewport.zoom(by: 1, at: CGPoint(x: size.width/2,y: size.height/2), in: size, pixelWidth: pixelWidth)
        requestRender()
    }
    func pan(_ delta: CGSize) { viewport.pan(by: delta, in: size) }
    func zoom(_ factor: Double, at point: CGPoint? = nil) {
        atPrecisionLimit = viewport.zoom(by: factor, at: point ?? CGPoint(x: size.width/2,y: size.height/2),
                                          in: size, pixelWidth: pixelWidth)
    }
    func perform(_ command: ExplorerCommand) {
        switch command {
        case .reset: viewport = Viewport(); atPrecisionLimit = false
        case .zoomIn: zoom(2)
        case .zoomOut: zoom(0.5)
        case .left: pan(CGSize(width: 80, height: 0))
        case .right: pan(CGSize(width: -80, height: 0))
        case .up: pan(CGSize(width: 0, height: 80))
        case .down: pan(CGSize(width: 0, height: -80))
        case .increaseIterations: iterations = min(65535, iterations * 2)
        case .decreaseIterations: iterations = max(1, iterations / 2)
        case .benchmark: showBenchmark.toggle()
        case .help: showHelp.toggle()
        }
    }
    func requestRender() {
        renderTask?.cancel()
        let view = viewport, renderer = renderer, iterations = iterations
        let width = max(1, Int(size.width * displayScale)), height = max(1, Int(size.height * displayScale))
        renderTask = Task { [weak self] in
            if renderer.isGPU {
                guard let self, let gpu = GPUContext.shared else { return }
                do {
                    while self.gpuBusy { try await Task.sleep(for: .milliseconds(8)) }
                    try Task.checkCancellation()
                    self.gpuBusy = true
                    defer { self.gpuBusy = false }
                    let start = DispatchTime.now().uptimeNanoseconds
                    for divisor in [8, 1] {
                        try Task.checkCancellation()
                        let frame = try await gpu.render(viewport:view,width:max(1,width/divisor),height:max(1,height/divisor),
                                                         iterations:iterations,renderer:renderer,settings:self.colouring)
                        try Task.checkCancellation()
                        self.gpuFrame = frame; self.imageViewport = view; self.error = nil
                    }
                    self.duration = Double(DispatchTime.now().uptimeNanoseconds-start)/1e9
                    self.progress = 1
                } catch is CancellationError { } catch { self.error = error.localizedDescription }
                return
            }
            let start = ContinuousClock.now
            for block in [32, 8, 2, 1] {
                guard !Task.isCancelled else { return }
                let image = await RenderWorker.shared.renderImage(variant: renderer.rawValue,
                    width: renderer.isGPU ? max(1,width/block) : width,
                    height: renderer.isGPU ? max(1,height/block) : height,
                    center: view.center, scale: view.scale, blockSize: block,
                    configuration: MandelbrotConfiguration(maxIterations: iterations))
                guard !Task.isCancelled, let self else { return }
                if let image { self.image = image; self.imageViewport = view; self.error = nil }
                else { self.error = "The renderer is unavailable." }
                self.progress = block == 1 ? 1 : 0.5
            }
            let elapsed = start.duration(to: .now).components
            self?.duration = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        }
    }
}
