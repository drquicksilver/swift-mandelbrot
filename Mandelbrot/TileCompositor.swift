import Foundation
import CoreGraphics
import Metal

@MainActor enum TileCompositor {
    static func encode(store: TileStore,viewport: Viewport,size: CGSize,gpu: GPUContext,encoder: MTLRenderCommandEncoder) {
        encoder.setRenderPipelineState(gpu.imagePipeline)
        for key in store.visible {
            guard let record=store.bestAvailable(for:key) else { continue }
            let bounds=store.grid.bounds(key)
            let center=viewport.screen(for:bounds.center,in:size)
            let width=bounds.span/viewport.span*size.width
            var params=DrawUniforms()
            params.rect=SIMD4(Float((center.x-width/2)/size.width*2-1),Float(1-(center.y-width/2)/size.height*2),
                             Float((center.x+width/2)/size.width*2-1),Float(1-(center.y+width/2)/size.height*2))
            let source=record.bounds
            let u=(bounds.left-source.left)/source.span,v=(source.top-bounds.top)/source.span,extent=bounds.span/source.span
            let resolution=Double(TileGrid.textureSize),interior=Double(TileGrid.samples)
            params.uv=SIMD4(Float((1+u*interior)/resolution),Float((1+v*interior)/resolution),
                           Float((1+(u+extent)*interior)/resolution),Float((1+(v+extent)*interior)/resolution))
            encoder.setVertexBytes(&params,length:MemoryLayout<DrawUniforms>.stride,index:0)
            encoder.setFragmentBytes(&params,length:MemoryLayout<DrawUniforms>.stride,index:0)
            encoder.setFragmentTexture(record.colour,index:0)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6)
        }
    }
    static func snapshot(store: TileStore,viewport: Viewport,width: Int,height: Int, sentinel: Bool = false) async throws -> MTLTexture {
        guard let gpu=GPUContext.shared else { throw GPUFailure("GPU unavailable") }
        let texture=try gpu.texture(width:width,height:height,format:.bgra8Unorm)
        let descriptor=MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture=texture
        descriptor.colorAttachments[0].loadAction = .clear;descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor=sentinel ? MTLClearColor(red:1,green:0,blue:1,alpha:1) : MTLClearColor(red:0.01,green:0.01,blue:0.02,alpha:1)
        guard let command=gpu.displayQueue.makeCommandBuffer(),let encoder=command.makeRenderCommandEncoder(descriptor:descriptor) else { throw GPUFailure("Compositor unavailable") }
        encode(store:store,viewport:viewport,size:CGSize(width:width,height:height),gpu:gpu,encoder:encoder)
        encoder.endEncoding();_ = try await gpu.submit(command)
        return texture
    }
}
