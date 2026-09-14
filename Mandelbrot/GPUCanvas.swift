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
        guard framesInFlight<2,let gpu=GPUContext.shared,let frame=model.gpuFrame,
              let descriptor=view.currentRenderPassDescriptor,let drawable=view.currentDrawable,
              let command=gpu.displayQueue.makeCommandBuffer(),let encoder=command.makeRenderCommandEncoder(descriptor:descriptor) else { return }
        let size=view.bounds.size
        let center=model.viewport.screen(for:model.imageViewport.center,in:size)
        let width=size.width*model.viewport.scale/model.imageViewport.scale
        let height=width*Double(frame.colour.height)/Double(frame.colour.width)
        var params=DrawUniforms()
        params.rect=SIMD4(Float((center.x-width/2)/size.width*2-1),Float(1-(center.y-height/2)/size.height*2),
                         Float((center.x+width/2)/size.width*2-1),Float(1-(center.y+height/2)/size.height*2))
        encoder.setRenderPipelineState(gpu.imagePipeline)
        encoder.setVertexBytes(&params,length:MemoryLayout<DrawUniforms>.stride,index:0)
        encoder.setFragmentBytes(&params,length:MemoryLayout<DrawUniforms>.stride,index:0)
        encoder.setFragmentTexture(frame.colour,index:0)
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6)
        encoder.endEncoding();command.present(drawable)
        framesInFlight += 1
        command.addCompletedHandler { [weak self] _ in Task { @MainActor in self?.framesInFlight -= 1 } }
        command.commit()
    }
}
