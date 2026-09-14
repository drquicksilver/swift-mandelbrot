import MetalKit
import SwiftUI

#if os(macOS)
  struct GPUCanvas: NSViewRepresentable {
    @ObservedObject var model: ExplorerModel
    func makeCoordinator() -> CanvasCoordinator { CanvasCoordinator(model: model) }
    func makeNSView(context: Context) -> MTKView { context.coordinator.makeView() }
    static func dismantleNSView(_ view: MTKView, coordinator: CanvasCoordinator) {
      view.isPaused = true
      view.delegate = nil
      coordinator.model.tiles.onContentChange = nil
      coordinator.model.tiles.cancel()
    }
    func updateNSView(_ view: MTKView, context: Context) {
      context.coordinator.model = model
      context.coordinator.wake()
    }
  }
#else
  struct GPUCanvas: UIViewRepresentable {
    @ObservedObject var model: ExplorerModel
    func makeCoordinator() -> CanvasCoordinator { CanvasCoordinator(model: model) }
    func makeUIView(context: Context) -> MTKView { context.coordinator.makeView() }
    static func dismantleUIView(_ view: MTKView, coordinator: CanvasCoordinator) {
      view.isPaused = true
      view.delegate = nil
      coordinator.model.tiles.onContentChange = nil
      coordinator.model.tiles.cancel()
    }
    func updateUIView(_ view: MTKView, context: Context) {
      context.coordinator.model = model
      context.coordinator.wake()
    }
  }
#endif

@MainActor final class CanvasCoordinator: NSObject, MTKViewDelegate {
  var model: ExplorerModel
  private var framesInFlight = 0
  private weak var view: MTKView?
  init(model: ExplorerModel) { self.model = model }
  func makeView() -> MTKView {
    let view = ScreenAwareMetalView(frame: .zero, device: GPUContext.shared?.device)
    self.view = view
    view.screenChanged = { [weak self] in self?.wake() }
    model.tiles.onContentChange = { [weak self] in self?.wake() }
    view.enableSetNeedsDisplay = true
    view.colorPixelFormat = .bgra8Unorm
    view.framebufferOnly = true
    view.clearColor = MTLClearColor(red: 0.01, green: 0.01, blue: 0.02, alpha: 1)
    view.delegate = self
    return view
  }
  func wake() {
    guard let view else { return }
    view.isPaused = !model.isActive
    #if os(macOS)
      view.preferredFramesPerSecond = view.window?.screen?.maximumFramesPerSecond ?? 60
    #else
      view.preferredFramesPerSecond = view.window?.screen.maximumFramesPerSecond ?? 60
    #endif
  }
  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
  func draw(in view: MTKView) {
    guard model.isActive, view.window != nil else { view.isPaused = true; return }
    let now = ProcessInfo.processInfo.systemUptime
    model.advanceMotion(now: ProcessInfo.processInfo.systemUptime)
    model.tiles.update(
      viewport: model.viewport, size: view.bounds.size, pixelWidth: view.drawableSize.width,
      iterations: model.iterations, override: model.rendererOverride, colouring: model.colouring,
      zoomDirection: model.zoomDirection)
    guard framesInFlight < 2, let gpu = GPUContext.shared,
      let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
      let command = gpu.displayQueue.makeCommandBuffer(),
      let encoder = command.makeRenderCommandEncoder(descriptor: descriptor)
    else { return }
    TileCompositor.encode(
      store: model.tiles, viewport: model.viewport, size: view.bounds.size, gpu: gpu,
      encoder: encoder, overlay: model.showTileOverlay)
    encoder.endEncoding()
    command.present(drawable)
    framesInFlight += 1
    command.addCompletedHandler { [weak self] result in
      let time = max(0, result.gpuEndTime - result.gpuStartTime)
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.framesInFlight -= 1
        self.model.tiles.recordFrame(seconds: time, now: ProcessInfo.processInfo.systemUptime)
      }
    }
    #if !targetEnvironment(simulator)
    drawable.addPresentedHandler { [weak self] drawable in
      let time = drawable.presentedTime
      Task { @MainActor [weak self] in self?.model.tiles.recordPresentation(at: time) }
    }
    #endif
    command.commit()
    model.tiles.retireFallback(now: now)
    view.isPaused = !model.motion.active && !model.tiles.hasActiveFades(now: now)
  }
}

@MainActor final class ScreenAwareMetalView: MTKView {
  var screenChanged: (() -> Void)?
  #if os(macOS)
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); screenChanged?() }
  #else
  override func didMoveToWindow() { super.didMoveToWindow(); screenChanged?() }
  #endif
}
