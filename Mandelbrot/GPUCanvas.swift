import SwiftUI
import MetalKit

#if os(macOS)
struct GPUCanvas: NSViewRepresentable {
    @ObservedObject var model: ExplorerModel
    func makeCoordinator() -> CanvasCoordinator { CanvasCoordinator(model:model) }
    func makeNSView(context: Context) -> MTKView { context.coordinator.makeView() }
    func updateNSView(_ view: MTKView,context: Context) { context.coordinator.model=model }
}
#else
struct GPUCanvas: UIViewRepresentable {
    @ObservedObject var model: ExplorerModel
    func makeCoordinator() -> CanvasCoordinator { CanvasCoordinator(model:model) }
    func makeUIView(context: Context) -> MTKView { context.coordinator.makeView() }
    func updateUIView(_ view: MTKView,context: Context) { context.coordinator.model=model }
}
#endif

@MainActor final class CanvasCoordinator: NSObject, @preconcurrency MTKViewDelegate {
    var model: ExplorerModel
    private var framesInFlight=0
    init(model: ExplorerModel) { self.model=model }
    func makeView() -> MTKView {
        let view=MTKView(frame:.zero,device:GPUContext.shared?.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly=true
        view.clearColor=MTLClearColor(red:0.01,green:0.01,blue:0.02,alpha:1)
        #if os(macOS)
        view.preferredFramesPerSecond=NSScreen.main?.maximumFramesPerSecond ?? 60
        #else
        view.preferredFramesPerSecond=UIScreen.main.maximumFramesPerSecond
        #endif
        view.delegate=self
        return view
    }
    func mtkView(_ view: MTKView,drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        model.advanceMotion(now:ProcessInfo.processInfo.systemUptime)
        model.tiles.update(viewport:model.viewport,size:view.bounds.size,pixelWidth:view.drawableSize.width,
                           iterations:model.iterations,override:model.rendererOverride,colouring:model.colouring,zoomDirection:model.zoomDirection)
        guard framesInFlight<2,let gpu=GPUContext.shared,
              let descriptor=view.currentRenderPassDescriptor,let drawable=view.currentDrawable,
              let command=gpu.displayQueue.makeCommandBuffer(),let encoder=command.makeRenderCommandEncoder(descriptor:descriptor) else { return }
        TileCompositor.encode(store:model.tiles,viewport:model.viewport,size:view.bounds.size,gpu:gpu,encoder:encoder)
        encoder.endEncoding();command.present(drawable)
        framesInFlight += 1
        command.addCompletedHandler { [weak self] _ in Task { @MainActor [weak self] in self?.framesInFlight -= 1 } }
        command.commit()
    }
}
