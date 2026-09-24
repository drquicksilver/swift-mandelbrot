// The Metal view for the Julia companion.  Unlike the tiled main view it draws
// one whole-panel texture from `JuliaRenderer`, re-rendered only when the point,
// the view, the detail or the colours change.

import MetalKit
import SwiftUI

/// Draws the Julia companion's texture.  It renders only when something it
/// depends on changes, then asks for one more frame to present the result.
///
/// The surface carries the scene it draws, not just the model: SwiftUI updates
/// a representable only when its value changes, and a surface holding nothing
/// but a model reference and a size never changed, so the panel was never
/// marked dirty and never seen to redraw.  The model's own redraw route backs
/// that up, so a frame does not depend on SwiftUI noticing.
struct JuliaCanvas: View {
  @ObservedObject var model: ExplorerModel
  var body: some View {
    GeometryReader { geometry in
      JuliaSurface(model: model, scene: model.juliaScene, size: geometry.size)
    }
  }
}

private struct JuliaSurface {
  var model: ExplorerModel
  var scene: JuliaScene
  var size: CGSize
}

@MainActor final class JuliaCoordinator: NSObject, MTKViewDelegate {
  var model: ExplorerModel
  private weak var view: MTKView?
  init(model: ExplorerModel) { self.model = model }
  /// SwiftUI hands over a fresh model value on each update; the panel's redraw
  /// route follows it, as the main canvas's does.
  func adopt(_ model: ExplorerModel, view: MTKView) {
    self.model = model
    self.view = view
    model.onJuliaRedrawNeeded = { [weak view] in view?.setNeedsDisplayCompat() }
    view.setNeedsDisplayCompat()
  }
  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
  func draw(in view: MTKView) {
    guard let gpu = GPUContext.shared, model.isActive else { return }
    // One dispatch draws the whole panel, so cap its pixels: a full-screen swap
    // on a Retina display would otherwise run millions of deep orbits at once.
    let pixels = max(1.0, view.drawableSize.width * view.drawableSize.height)
    let shrink = min(1, sqrt(2_200_000 / pixels))
    let width = max(16, Int(view.drawableSize.width * shrink))
    let height = max(16, Int(view.drawableSize.height * shrink))
    let iterations = model.iterations
    Task { @MainActor in
      let updated = await model.julia.update(
        c: model.juliaC, viewport: model.juliaViewport, width: width, height: height,
        iterations: iterations, colouring: model.colouring, gpu: gpu)
      if updated { view.setNeedsDisplayCompat() }
    }
    guard let colour = model.julia.colour, let descriptor = view.currentRenderPassDescriptor,
      let drawable = view.currentDrawable, let command = gpu.displayQueue.makeCommandBuffer(),
      let encoder = command.makeRenderCommandEncoder(descriptor: descriptor)
    else { return }
    encoder.setRenderPipelineState(gpu.imagePipeline)
    var uniforms = DrawUniforms()
    encoder.setVertexBytes(&uniforms, length: MemoryLayout<DrawUniforms>.stride, index: 0)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DrawUniforms>.stride, index: 0)
    encoder.setFragmentTexture(colour, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    encoder.endEncoding()
    command.present(drawable)
    command.commit()
  }
}

#if os(macOS)
  extension JuliaSurface: NSViewRepresentable {
    func makeCoordinator() -> JuliaCoordinator { JuliaCoordinator(model: model) }
    func makeNSView(context: Context) -> MTKView { makeView(context.coordinator) }
    func updateNSView(_ view: MTKView, context: Context) {
      context.coordinator.adopt(model, view: view)
    }
  }
#else
  extension JuliaSurface: UIViewRepresentable {
    func makeCoordinator() -> JuliaCoordinator { JuliaCoordinator(model: model) }
    func makeUIView(context: Context) -> MTKView { makeView(context.coordinator) }
    func updateUIView(_ view: MTKView, context: Context) {
      context.coordinator.adopt(model, view: view)
    }
  }
#endif

extension JuliaSurface {
  @MainActor fileprivate func makeView(_ coordinator: JuliaCoordinator) -> MTKView {
    let view = MTKView(frame: .zero, device: GPUContext.shared?.device)
    view.delegate = coordinator
    view.enableSetNeedsDisplay = true
    view.isPaused = true
    view.colorPixelFormat = .bgra8Unorm
    view.framebufferOnly = true
    view.clearColor = MTLClearColor(red: 0.01, green: 0.01, blue: 0.02, alpha: 1)
    coordinator.adopt(model, view: view)
    return view
  }
}
