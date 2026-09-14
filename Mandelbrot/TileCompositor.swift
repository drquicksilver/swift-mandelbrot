import CoreGraphics
import Foundation
import Metal

struct TileDrawUniforms {
  var rect = SIMD4<Float>(-1, 1, 1, -1)
  var coarseUV = SIMD4<Float>(0, 0, 1, 1)
  var baseUV = SIMD4<Float>(0, 0, 1, 1)
  var fineUV = SIMD4<Float>(0, 0, 1, 1)
  var baseMix: Float = 1
  var fineMix: Float = 0
  var border: UInt32 = 0
  var level: Int32 = 0
}

@MainActor enum TileCompositor {
  static func uv(cell: TileBounds, source: TileBounds) -> SIMD4<Float> {
    let u = (cell.left - source.left) / source.span
    let v = (source.top - cell.top) / source.span
    let extent = cell.span / source.span
    let resolution = Double(TileGrid.textureSize)
    let interior = Double(TileGrid.samples)
    return SIMD4(
      Float((1 + u * interior) / resolution), Float((1 + v * interior) / resolution),
      Float((1 + (u + extent) * interior) / resolution),
      Float((1 + (v + extent) * interior) / resolution))
  }
  static func encode(
    store: TileStore, viewport: Viewport, size: CGSize, gpu: GPUContext,
    encoder: MTLRenderCommandEncoder,
    now: Double = ProcessInfo.processInfo.systemUptime, overlay: Bool = false
  ) {
    encoder.setRenderPipelineState(gpu.tilePipeline)
    let floorLevel = Int(floor(store.lod))
    for key in store.visible {
      let baseKey = key.ancestor(at: min(key.level, floorLevel))
      guard let base = store.bestAvailable(for: baseKey) else { continue }
      let coarse =
        (base.key.anchorID == store.grid.anchorID && base.key.level > store.minimumLevel
          ? store.bestAvailable(for: base.key.parent) : nil) ?? base
      let fine = store.records[key] ?? base
      let cell = store.grid.bounds(key)
      let center = viewport.screen(for: cell.center, in: size)
      let width = cell.span / viewport.span * size.width
      var params = TileDrawUniforms()
      params.rect = SIMD4(
        Float((center.x - width / 2) / size.width * 2 - 1),
        Float(1 - (center.y - width / 2) / size.height * 2),
        Float((center.x + width / 2) / size.width * 2 - 1),
        Float(1 - (center.y + width / 2) / size.height * 2))
      params.coarseUV = uv(cell: cell, source: coarse.bounds)
      params.baseUV = uv(cell: cell, source: base.bounds)
      params.fineUV = uv(cell: cell, source: fine.bounds)
      params.baseMix = coarse === base ? 1 : TilePresentation.fade(readyAt: base.readyAt, now: now)
      params.fineMix =
        fine === base
        ? 0 : TilePresentation.fineWeight(lod: store.lod, readyAt: fine.readyAt, now: now)
      params.border = overlay ? 1 : 0
      params.level = Int32(base.key.level)
      encoder.setVertexBytes(&params, length: MemoryLayout<TileDrawUniforms>.stride, index: 0)
      encoder.setFragmentBytes(&params, length: MemoryLayout<TileDrawUniforms>.stride, index: 0)
      encoder.setFragmentTexture(coarse.colour, index: 0)
      encoder.setFragmentTexture(base.colour, index: 1)
      encoder.setFragmentTexture(fine.colour, index: 2)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
  }
  static func snapshot(
    store: TileStore, viewport: Viewport, width: Int, height: Int, sentinel: Bool = false,
    now: Double = ProcessInfo.processInfo.systemUptime, overlay: Bool = false
  ) async throws -> MTLTexture {
    guard let gpu = GPUContext.shared else { throw GPUFailure("GPU unavailable") }
    let texture = try gpu.texture(width: width, height: height, format: .bgra8Unorm)
    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = texture
    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].storeAction = .store
    descriptor.colorAttachments[0].clearColor =
      sentinel
      ? MTLClearColor(red: 1, green: 0, blue: 1, alpha: 1)
      : MTLClearColor(red: 0.01, green: 0.01, blue: 0.02, alpha: 1)
    guard let command = gpu.displayQueue.makeCommandBuffer(),
      let encoder = command.makeRenderCommandEncoder(descriptor: descriptor)
    else { throw GPUFailure("Compositor unavailable") }
    encode(
      store: store, viewport: viewport, size: CGSize(width: width, height: height), gpu: gpu,
      encoder: encoder, now: now, overlay: overlay)
    encoder.endEncoding()
    let time = try await gpu.submit(command)
    store.recordFrame(seconds: time, now: ProcessInfo.processInfo.systemUptime)
    return texture
  }
}
