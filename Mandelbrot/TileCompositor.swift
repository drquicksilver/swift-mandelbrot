import CoreGraphics
import Foundation
import Metal

struct TileDrawUniforms {
  var rect = SIMD4<Float>(-1, 1, 1, -1)
  var coarseUV = SIMD4<Float>(0, 0, 1, 1)
  var baseUV = SIMD4<Float>(0, 0, 1, 1)
  var fineUV = SIMD4<Float>(0, 0, 1, 1)
  var previousFineUV = SIMD4<Float>(0, 0, 1, 1)
  var baseMix: Float = 1
  var fineMix: Float = 0
  var border: UInt32 = 0
  var level: Int32 = 0
  var fineFade: Float = 1
  var padding0: Float = 0, padding1: Float = 0, padding2: Float = 0
}

@MainActor enum TileCompositor {
  static func uv(cell: TileBounds, source: TileBounds) -> SIMD4<Float> {
    let (u, v, extent) = cell.relative(to: source)
    let resolution = Double(TileGrid.textureSize)
    let interior = Double(TileGrid.samples)
    return SIMD4(
      Float((1 + u * interior) / resolution), Float((1 + v * interior) / resolution),
      Float((1 + (u + extent) * interior) / resolution),
      Float((1 + (v + extent) * interior) / resolution))
  }
  struct CellPlan {
    let key: TileKey
    let coarse: TileRecord
    let base: TileRecord
    let fine: TileRecord
    let previousFine: TileRecord
    let baseIsPlaceholder: Bool
    let fineIsGenuine: Bool
    var uniforms: TileDrawUniforms
  }
  /// Composition is decided here and only encoded below, so headless checks can
  /// inspect the same choices the display makes.
  static func plan(
    store: TileStore, viewport: Viewport, size: CGSize,
    now: Double = ProcessInfo.processInfo.systemUptime, overlay: Bool = false
  ) -> [CellPlan] {
    guard let first = store.visible.first else { return [] }
    let projection = TileProjection(origin: store.bounds(first), viewport: viewport, size: size)
    let floorLevel = Int(floor(store.lod))
    var plans: [CellPlan] = []
    for key in store.visible {
      let baseKey = key.ancestor(at: min(key.level, floorLevel))
      guard let base = store.bestAvailable(for: baseKey) ?? store.bestAvailable(for: key) else {
        continue
      }
      let transition = store.presentBase(base, for: key, now: now)
      let oldBase = store.fallbackAvailable(for: key, maximumLevel: base.key.level)
      let coarse =
        transition.previous
        ?? (oldBase !== base ? oldBase : nil)
        ?? (base.key.anchorID == store.grid.anchorID && base.key.level > store.minimumLevel
          ? store.bestAvailable(for: base.key.parent) : nil) ?? base
      let fine = store.bestAvailable(for: key) ?? base
      let oldFine = store.fallbackAvailable(for: key)
      let previousFine = (oldFine !== fine ? oldFine : nil) ?? fine
      let cell = store.bounds(key)
      let center = projection.center(of: cell)
      let width = cell.wideSpan / viewport.wideSpan * size.width
      var params = TileDrawUniforms()
      params.rect = SIMD4(
        Float((center.x - width / 2) / size.width * 2 - 1),
        Float(1 - (center.y - width / 2) / size.height * 2),
        Float((center.x + width / 2) / size.width * 2 - 1),
        Float(1 - (center.y + width / 2) / size.height * 2))
      params.coarseUV = uv(cell: cell, source: coarse.bounds)
      params.baseUV = uv(cell: cell, source: base.bounds)
      params.fineUV = uv(cell: cell, source: fine.bounds)
      params.previousFineUV = uv(cell: cell, source: previousFine.bounds)
      params.baseMix = coarse === base ? 1 : transition.fade
      params.fineFade =
        previousFine === fine ? 1 : TilePresentation.fade(readyAt: fine.readyAt, now: now)
      let baseIsPlaceholder = store.isPlaceholder(base)
      let fineIsGenuine = fine !== base && !store.isPlaceholder(fine)
      // The cross-fade weight only means anything when the base really is this
      // cell's floor-level tile.  A stand-in must never outvote detail the store
      // already holds for the exact cell.
      params.fineMix =
        fine === base
        ? 0
        : baseIsPlaceholder && fineIsGenuine
          ? 1
          : (previousFine === fine && store.records[fine.key] === fine
            ? TilePresentation.fineWeight(lod: store.lod, readyAt: fine.readyAt, now: now)
            : Float(store.lod - floor(store.lod)))
      params.border = overlay ? 1 : 0
      params.level = Int32(base.key.level)
      plans.append(
        CellPlan(
          key: key, coarse: coarse, base: base, fine: fine, previousFine: previousFine,
          baseIsPlaceholder: baseIsPlaceholder, fineIsGenuine: fineIsGenuine, uniforms: params))
    }
    return plans
  }
  static func encode(
    store: TileStore, viewport: Viewport, size: CGSize, gpu: GPUContext,
    encoder: MTLRenderCommandEncoder,
    now: Double = ProcessInfo.processInfo.systemUptime, overlay: Bool = false
  ) {
    let start = ProcessInfo.processInfo.systemUptime
    defer { store.recordPreparation(seconds: ProcessInfo.processInfo.systemUptime - start) }
    let cells = plan(store: store, viewport: viewport, size: size, now: now, overlay: overlay)
    guard !cells.isEmpty else { return }
    encoder.setRenderPipelineState(gpu.tilePipeline)
    for cell in cells {
      var params = cell.uniforms
      encoder.setVertexBytes(&params, length: MemoryLayout<TileDrawUniforms>.stride, index: 0)
      encoder.setFragmentBytes(&params, length: MemoryLayout<TileDrawUniforms>.stride, index: 0)
      encoder.setFragmentTexture(cell.coarse.colour, index: 0)
      encoder.setFragmentTexture(cell.base.colour, index: 1)
      encoder.setFragmentTexture(cell.fine.colour, index: 2)
      encoder.setFragmentTexture(cell.previousFine.colour, index: 3)
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
