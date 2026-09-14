#if os(macOS)
  import AppKit
  import Foundation
  import CoreGraphics
  import Metal

  /// Headless integration checks run the same tile store and compositor as MTKView.
  @MainActor enum TileDiagnostics {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
      if !condition() { throw GPUFailure(message) }
    }
    static func checkColourBlend(_ gpu: GPUContext) async throws {
      let target = try gpu.texture(width: 4, height: 4, format: .bgra8Unorm)
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = target
      pass.colorAttachments[0].loadAction = .clear
      pass.colorAttachments[0].storeAction = .store
      let command = gpu.displayQueue.makeCommandBuffer()!
      let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
      encoder.setRenderPipelineState(gpu.tilePipeline)
      var params = TileDrawUniforms()
      params.baseMix = 0.25
      params.fineMix = 0.5
      encoder.setVertexBytes(&params, length: MemoryLayout<TileDrawUniforms>.stride, index: 0)
      encoder.setFragmentBytes(&params, length: MemoryLayout<TileDrawUniforms>.stride, index: 0)
      for (index, bytes) in [
        [UInt8](arrayLiteral: 0, 0, 255, 255), [255, 0, 0, 255], [0, 255, 0, 255],
      ].enumerated() {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
          pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let texture = gpu.device.makeTexture(descriptor: descriptor)!
        bytes.withUnsafeBytes {
          texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!,
            bytesPerRow: 4)
        }
        encoder.setFragmentTexture(texture, index: index)
        if index == 0 { encoder.setFragmentTexture(texture, index: 3) }
      }
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
      encoder.endEncoding()
      _ = try await gpu.submit(command)
      let bytes = try await gpu.readback(target)
      for index in stride(from: 0, to: bytes.count, by: 4) {
        try require(
          abs(Int(bytes[index]) - 96) <= 1 && abs(Int(bytes[index + 1]) - 128) <= 1
            && abs(Int(bytes[index + 2]) - 32) <= 1, "GPU did not blend coloured levels correctly")
      }
    }
    static func checkHighIterationColour(_ gpu: GPUContext) async throws {
      let far = try gpu.texture(width: 1, height: 1, format: .rg32Uint)
      var params = GPUParameters(
        viewport: Viewport(center: CGPoint(x: 1e20, y: 0), scale: 1),
        width: 1, height: 1, iterations: 10, renderer: .metal)
      params.smooth = 1
      _ = try await gpu.compute(into: far, parameters: params)
      let raw = try await gpu.readback(far)
      let record = raw.withUnsafeBytes { $0.load(as: SampleRecord.self) }
      try require(
        record.iteration == 1 && record.legacyFloat == 0,
        "Clamping the smooth value changed the integer escape count")
      let values = [
        SampleRecord(iteration: 1_000_000, correction: 0.003),
        SampleRecord(iteration: 1_000_000, correction: 0.02),
        SampleRecord(iteration: 999_999, correction: -2.003),
      ]
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rg32Uint,
        width: values.count, height: 1, mipmapped: false)
      descriptor.storageMode = .shared
      descriptor.usage = .shaderRead
      let samples = gpu.device.makeTexture(descriptor: descriptor)!
      values.withUnsafeBytes { bytes in
        samples.replace(
          region: MTLRegionMake2D(0, 0, values.count, 1), mipmapLevel: 0,
          withBytes: bytes.baseAddress!, bytesPerRow: values.count * 8)
      }
      let output = try gpu.texture(width: values.count, height: 1, format: .rgba8Unorm)
      let settings = ColourSettings(palette: .ink, density: 1, offset: 0.25)
      _ = try await gpu.colour(samples, into: output, settings: settings)
      let bytes = try await gpu.readback(output)
      let lut = settings.palette.lookupTable()
      for (i, value) in values.enumerated() {
        let phase = Double(value.iteration) + Double(value.correction) + Double(settings.offset)
        let coordinate = (phase - floor(phase)) * 1024 - 0.5
        let index = Int(floor(coordinate))
        let fraction = coordinate - floor(coordinate)
        for channel in 0..<3 {
          let a = Double(lut[((index + 1024) % 1024) * 4 + channel])
          let b = Double(lut[((index + 1025) % 1024) * 4 + channel])
          let expected = Int((a * (1 - fraction) + b * fraction).rounded())
          try require(
            abs(Int(bytes[i * 4 + channel]) - expected) <= 1,
            "High-count palette phase lost its fractional correction")
        }
      }
      try require(bytes[0] != bytes[4], "Distinct high-count corrections collapsed to one colour")
    }
    static func checkDepthControls() async throws {
      let model = ExplorerModel()
      model.viewport = try Viewport(real: "0", imag: "1", zoom: "1e1000")
      try require(model.iterations > 65535, "Depth estimate retained the legacy cap")
      let deep = model.iterations
      model.interactionActive = true
      model.viewport = Viewport()
      try await Task.sleep(for: .milliseconds(350))
      try require(model.iterations == deep, "Iteration limit decreased during a gesture")
      model.interactionActive = false
      try await Task.sleep(for: .milliseconds(350))
      try require(model.iterations == 200, "Iteration limit did not decrease at idle")
      model.automaticIterations = false
      model.manualIterations = 800000
      model.perform(.increaseIterations)
      try require(
        model.iterations == IterationPolicy.maximum, "Keyboard and manual limits disagree")
      model.setActive(false)
    }
    static func checkResumption(_ gpu: GPUContext) async throws {
      for renderer in [RendererID.metal, .metalDouble] {
        let width = 66
        let height = 53
        var params = GPUParameters(
          viewport: Viewport(
            center: CGPoint(x: -0.743643887037151, y: 0.13182590390533), scale: 1e7), width: width,
          height: height, iterations: 2000, renderer: renderer)
        params.smooth = 1
        let full = try gpu.texture(width: width, height: height, format: .rg32Uint)
        let sliced = try gpu.texture(width: width, height: height, format: .rg32Uint)
        let states = gpu.device.makeBuffer(
          length: width * height * 16, options: .storageModePrivate)!
        _ = try await gpu.compute(into: full, parameters: params)
        for start in stride(from: 0, to: 2000, by: 37) {
          _ = try await gpu.resume(
            into: sliced, states: states, parameters: params, start: start,
            count: min(37, 2000 - start))
        }
        let expected = try await gpu.readback(full)
        let actual = try await gpu.readback(sliced)
        try require(expected == actual, "Resuming \(renderer.rawValue) changed sample values")
      }
    }
    static func checkMipmaps(_ gpu: GPUContext) async throws {
      var children: [MTLTexture] = []
      var inputs: [[UInt8]] = []
      for quadrant in 0..<4 {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
          pixelFormat: .rgba8Unorm, width: 258, height: 258, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let texture = gpu.device.makeTexture(descriptor: descriptor)!
        var bytes = [UInt8](repeating: 255, count: 258 * 258 * 4)
        for y in 0..<258 {
          for x in 0..<258 {
            let offset = (y * 258 + x) * 4
            bytes[offset] = UInt8((x * 7 + quadrant * 29) % 256)
            bytes[offset + 1] = UInt8((y * 3 + quadrant * 43) % 256)
            bytes[offset + 2] = UInt8((x + y + quadrant * 61) % 256)
          }
        }
        bytes.withUnsafeBytes {
          texture.replace(
            region: MTLRegionMake2D(0, 0, 258, 258), mipmapLevel: 0, withBytes: $0.baseAddress!,
            bytesPerRow: 258 * 4)
        }
        children.append(texture)
        inputs.append(bytes)
      }
      let result = try await gpu.average(children: children, parent: children[0])
      let bytes = try await gpu.readback(result)
      for y in 0..<258 {
        for x in 0..<258 {
          for channel in 0..<4 {
            let offset = (y * 258 + x) * 4 + channel
            if x == 0 || y == 0 || x == 257 || y == 257 {
              try require(bytes[offset] == inputs[0][offset], "Mipmap changed the sampled gutter")
            } else {
              let cx = (x - 1) * 2
              let cy = (y - 1) * 2
              let q = cx / 256 + cy / 256 * 2
              let ix = cx % 256 + 1
              let iy = cy % 256 + 1
              let values = [
                inputs[q][(iy * 258 + ix) * 4 + channel],
                inputs[q][(iy * 258 + ix + 1) * 4 + channel],
                inputs[q][((iy + 1) * 258 + ix) * 4 + channel],
                inputs[q][((iy + 1) * 258 + ix + 1) * 4 + channel],
              ]
              let expected = Double(values.reduce(0) { $0 + Int($1) }) / 4
              try require(
                abs(Double(bytes[offset]) - expected) <= 0.51,
                "Parent is not the box average of its children")
            }
          }
        }
      }
    }
    static func checkCache() async throws -> [String: Double] {
      // Keep complete prefetched sibling groups resident with eight-byte raw samples.
      // Separate constrained-cache checks below still exercise LOD reduction and eviction.
      let store = TileStore(budgetBytes: 64 * 1024 * 1024)
      let size = CGSize(width: 256, height: 256)
      var view = Viewport()
      store.update(
        viewport: view, size: size, pixelWidth: 256, iterations: 200, override: nil,
        colouring: ColourSettings(), zoomDirection: 1)
      try await store.waitUntilReady()
      try require(store.statistics.prefetched > 0, "Zoom direction did not prefetch")
      try require(store.statistics.mipmaps > 0, "Complete children did not build parent mipmaps")
      let mipSamples = store.records.mapValues { $0.samples }
      let mipCount = store.statistics.mipmaps
      let computed = store.statistics.computed
      store.update(
        viewport: view, size: size, pixelWidth: 256, iterations: 200, override: nil,
        colouring: ColourSettings(palette: .ice))
      try await store.waitUntilReady()
      try require(
        store.statistics.computed == computed && store.statistics.mipmaps > mipCount,
        "Palette change failed to rebuild colour mipmaps without sampling")
      for (key, samples) in mipSamples {
        try require(
          store.records[key]?.samples === samples, "Palette change replaced authoritative raw data")
      }
      for step in 1...12 {
        view.center.x = -0.5 + Double(step) * 2
        store.update(
          viewport: view, size: size, pixelWidth: 256, iterations: 200, override: nil,
          colouring: ColourSettings())
        try await store.waitUntilReady()
        try require(store.statistics.bytes < store.budgetBytes, "Cache exceeded memory budget")
        try require(
          store.needed.allSatisfy { store.records[$0] != nil }, "Evicted a visible tile or ancestor"
        )
      }
      try require(store.statistics.evictions > 0, "Cache did not evict old tiles")
      view = Viewport()
      store.update(
        viewport: view, size: size, pixelWidth: 256, iterations: 65535, override: .metalDouble,
        colouring: ColourSettings())
      try await Task.sleep(for: .milliseconds(4))
      store.update(
        viewport: view, size: size, pixelWidth: 256, iterations: 200, override: nil,
        colouring: ColourSettings())
      try await store.waitUntilReady()
      try require(store.statistics.cancelled > 0, "Superseded work was not cancelled")
      // A deep location forces rebasing of relative keys; every ancestor must
      // remain representable and the FloatFloat tile path must finish.
      view = Viewport(center: CGPoint(x: -0.743643887037151, y: 0.13182590390533), scale: 1e10)
      let deep = TileStore(budgetBytes: 150 * 1024 * 1024)
      let deepStart = ProcessInfo.processInfo.systemUptime
      deep.update(
        viewport: view, size: size, pixelWidth: 256, iterations: 4000, override: nil,
        colouring: ColourSettings())
      while !deep.visible.allSatisfy({ deep.bestAvailable(for: $0) != nil }) {
        if let error = deep.error { throw GPUFailure(error) }
        try await Task.sleep(for: .milliseconds(1))
      }
      let usefulMS = (ProcessInfo.processInfo.systemUptime - deepStart) * 1000
      try await deep.waitUntilReady()
      try require(
        deep.lod == deep.grid.idealLevel(viewport: view, pixelWidth: 256),
        "Phone memory budget silently reduced deep detail")
      try require(deep.needed.count <= 12, "Cold view still requires distant ancestors")
      try require(
        deep.statistics.bytes < 20 * 1024 * 1024, "Deep working set is unexpectedly large")
      try require(deep.grid.anchorID > 0, "Deep coordinates did not rebase")
      try require(
        deep.needed.allSatisfy { deep.records[$0] != nil }, "Deep ancestors are incomplete")
      let deepMS = (ProcessInfo.processInfo.systemUptime - deepStart) * 1000
      deep.cancel()
      store.cancel()
      return [
        "deepUsefulMS": usefulMS, "deepLOD": deep.lod,
        "deepRefinementMS": deepMS, "deepLongestBatchMS": deep.statistics.longestBatchMS,
        "deepResidentBytes": Double(deep.statistics.bytes),
        "cacheEvictions": Double(store.statistics.evictions),
        "cacheMipmaps": Double(store.statistics.mipmaps),
        "cachePrefetched": Double(store.statistics.prefetched),
      ]
    }
    static func checkFailureRecovery() async throws {
      var allocations = 0
      var fail = true
      let store = TileStore(retryDelay: .milliseconds(1)) { _ in
        allocations += 1
        if fail { throw GPUFailure("Injected allocation failure") }
      }
      let size = CGSize(width: 128, height: 128)
      func update() {
        store.update(
          viewport: Viewport(), size: size, pixelWidth: 128,
          iterations: 200, override: nil, colouring: ColourSettings())
      }
      update()
      do {
        try await store.waitUntilReady()
        throw GPUFailure("Failure was hidden")
      } catch { try require(store.error != nil, "Failure was not reported") }
      try require(allocations == 3, "Retry budget was not enforced")
      for _ in 0..<120 { update() }
      try await Task.sleep(for: .milliseconds(5))
      try require(allocations == 3, "Failed allocations restarted at display rate")
      fail = false
      store.retryFailedWork()
      try await store.waitUntilReady()
      try require(store.error == nil && store.allVisibleReady, "Explicit retry did not recover")
    }
    static func checkIterationContinuity(_ gpu: GPUContext) async throws {
      let store = TileStore(budgetBytes: 150 * 1024 * 1024)
      let view = Viewport(center: CGPoint(x: -0.743643987037151, y: 0.13182597420533), scale: 1e7)
      let size = CGSize(width: 256, height: 256)
      func update(_ iterations: Int) {
        store.update(
          viewport: view, size: size, pixelWidth: 256, iterations: iterations,
          override: nil, colouring: ColourSettings())
      }
      update(2000)
      try await store.waitUntilReady()
      let settled = ProcessInfo.processInfo.systemUptime + 1
      let before = try await gpu.readback(
        TileCompositor.snapshot(
          store: store, viewport: view,
          width: 256, height: 256, now: settled))
      update(2200)
      try require(!store.fallback.isEmpty, "Iteration change discarded detailed fallback")
      let after = try await gpu.readback(
        TileCompositor.snapshot(
          store: store, viewport: view,
          width: 256, height: 256, now: 0))
      try require(
        before == after, "Iteration change altered the picture before replacement was ready")
      update(2400)
      try require(
        store.visible.allSatisfy { store.bestAvailable(for: $0)?.key.level == $0.level },
        "Repeated invalidation lost fine coverage")
      try await store.waitUntilReady()
      try require(
        store.visible.allSatisfy { store.records[$0]?.iterations == 2400 },
        "Stale iteration generation was published")
      store.retireFallback(now: ProcessInfo.processInfo.systemUptime + 1)
      try require(store.fallback.isEmpty, "Completed fallback was not released")
    }
    static func checkDemandWakeups() async throws {
      let store = TileStore()
      let size = CGSize(width: 256, height: 256)
      var notifications = 0
      store.onContentChange = { notifications += 1 }
      func update(_ palette: Palette = .blueGold) {
        store.update(
          viewport: Viewport(), size: size, pixelWidth: 256, iterations: 200,
          override: nil, colouring: ColourSettings(palette: palette))
      }
      update()
      try await store.waitUntilReady()
      let updates = store.statistics.demandUpdates
      let initial = notifications
      for _ in 0..<120 { update() }
      try require(notifications == initial, "Idle updates scheduled content changes")
      store.recordFrame(seconds: 0, now: ProcessInfo.processInfo.systemUptime + 1)
      try require(store.statistics.demandUpdates == updates, "Idle frames rebuilt demand")
      try require(
        !store.hasActiveFades(now: ProcessInfo.processInfo.systemUptime + 1),
        "Settled tiles keep drawing alive")
      update(.fire)
      try await store.waitUntilReady()
      try require(notifications > initial, "Palette completion did not wake presentation")
      store.cancel()
      update(.fire)
      try await store.waitUntilReady()
      try require(store.allVisibleReady, "Resuming unchanged demand lost readiness")
    }
    static func checkNativeCommands() throws {
      func event(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
          windowNumber: 0, context: nil, characters: characters,
          charactersIgnoringModifiers: characters,
          isARepeat: false, keyCode: code)!
      }
      try require(ExplorerCommand.matching(event("", code: 123)) == .left, "Arrow command missing")
      try require(
        ExplorerCommand.matching(event("?", code: 44, flags: .shift)) == .help,
        "Help command missing")
      try require(
        ExplorerCommand.matching(event("h", code: 4, flags: .shift)) == .reset,
        "Reset command missing")
      try require(
        ExplorerCommand.matching(event("h", code: 4)) == nil, "Incorrect modifier triggered reset")
      let model = ExplorerModel()
      model.fling(pan: CGPoint(x: 100, y: 0))
      try require(model.motionActive, "Fling did not signal input-clock wakeup")
      model.stopMotion()
      try require(!model.motionActive, "Stopped motion left input clock active")
    }
    static func checkDeepTiles(_ gpu: GPUContext) async throws -> [String: Double] {
      try require(
        MemoryLayout<ExtendedFloat>.stride == 16 && MemoryLayout<ExtendedComplex>.stride == 32
          && MemoryLayout<BLAEntry>.stride == 96, "Perturbation Metal ABI changed")
      let store = TileStore(budgetBytes: 150 * 1024 * 1024)
      let pool = store.perturbationResources
      let scratch = try pool.acquire(device: gpu.device, length: 258 * 258 * 48)
      pool.recycle(scratch)
      let reused = try pool.acquire(device: gpu.device, length: 258 * 258 * 48)
      try require(scratch === reused, "Tile worker did not reuse its state buffer")
      pool.recycle(reused)
      let size = CGSize(width: 256, height: 192)
      var view = try Viewport(real: "0", imag: "1", zoom: "1e1000")
      let start = ProcessInfo.processInfo.systemUptime
      store.update(
        viewport: view, size: size, pixelWidth: 256, iterations: 5000, override: nil,
        colouring: ColourSettings(density: 8))
      try await store.waitUntilReady()
      let completed = ProcessInfo.processInfo.systemUptime - start
      try require(
        store.lod > 3300 && store.statistics.tiles <= 16,
        "Deep tile levels were clamped or unbounded")
      try require(
        store.statistics.referenceCacheHits > 0 && store.statistics.perturbationSkipped > 0,
        "Deep tiles did not share references or use BLA")
      let initial = try await gpu.readback(
        TileCompositor.snapshot(
          store: store, viewport: view, width: 256, height: 192,
          now: ProcessInfo.processInfo.systemUptime + 1))
      try require(Set(initial).count > 100, "Deep compositor is flat")
      for _ in 0..<120 {
        _ = try await TileCompositor.snapshot(store: store, viewport: view, width: 256, height: 192)
      }
      view.zoom(by: 1.15, at: CGPoint(x: 128, y: 96), in: size, pixelWidth: 256)
      store.update(
        viewport: view, size: size, pixelWidth: 256, iterations: 5000, override: nil,
        colouring: ColourSettings(density: 8))
      let fallback = try await gpu.readback(
        TileCompositor.snapshot(
          store: store, viewport: view, width: 256, height: 192, sentinel: true))
      for i in stride(from: 0, to: fallback.count, by: 4) {
        try require(
          !(fallback[i] == 255 && fallback[i + 1] == 0 && fallback[i + 2] == 255),
          "Deep parent fallback left a hole")
      }
      try await store.waitUntilReady()
      try require(
        store.residentBytes < 20 * 1024 * 1024, "Deep tile memory exceeded local-band budget")
      // Cancel a long CPU reference/GPU workload and recover the same store.
      store.update(
        viewport: view, size: size, pixelWidth: 256, iterations: 65535, override: nil,
        colouring: ColourSettings())
      try await Task.sleep(for: .milliseconds(2))
      store.cancel()
      store.update(
        viewport: view, size: size, pixelWidth: 256, iterations: 5000, override: nil,
        colouring: ColourSettings())
      try await store.waitUntilReady()
      return [
        "perturbation1e1000ReadyMS": completed * 1000,
        "deepPreparationP95MS": store.statistics.preparationP95MS,
        "deepPreparationMaxMS": store.statistics.preparationMaxMS,
        "perturbationReferenceCacheHits": Double(store.statistics.referenceCacheHits),
        "perturbationMaxBatchMS": store.statistics.longestBatchMS,
        "perturbationResidentMiB": Double(store.residentBytes) / 1_048_576,
      ]
    }
    static func run() async -> Int32 {
      do {
        guard let gpu = GPUContext.shared else { throw GPUFailure("GPU unavailable") }
        for palette in Palette.allCases {
          let first = try gpu.paletteTexture(palette)
          let second = try gpu.paletteTexture(palette)
          try require(first === second, "Palette GPU texture was rebuilt")
        }
        try checkNativeCommands()
        try await checkDemandWakeups()
        try await checkIterationContinuity(gpu)
        try await checkFailureRecovery()
        try await checkColourBlend(gpu)
        try await checkHighIterationColour(gpu)
        try await checkDepthControls()
        try await checkResumption(gpu)
        try await checkMipmaps(gpu)
        let cacheMetrics = try await checkCache()
        let deepMetrics = try await checkDeepTiles(gpu)
        let store = TileStore()
        let size = CGSize(width: 512, height: 320)
        var view = Viewport()
        let start = DispatchTime.now().uptimeNanoseconds
        store.update(
          viewport: view, size: size, pixelWidth: 512, iterations: 200, override: nil,
          colouring: ColourSettings())
        try await store.waitUntilReady()
        let first = store.statistics.computed
        let records = store.records
        try require(first > 0, "No tiles computed")
        let frame = try await TileCompositor.snapshot(
          store: store, viewport: view, width: 512, height: 320)
        let data = try await gpu.readback(frame)
        let center = (160 * 512 + 256) * 4
        try require(
          data[center] < 8 && data[center + 1] < 8 && data[center + 2] < 8,
          "Interior colour is incorrect")
        try require(Set(data).count > 100, "Compositor is flat")
        view.pan(by: CGSize(width: 20, height: 0), in: size)
        store.update(
          viewport: view, size: size, pixelWidth: 512, iterations: 200, override: nil,
          colouring: ColourSettings())
        try await store.waitUntilReady()
        let shared = store.records.keys.filter { records[$0] != nil }
        try require(!shared.isEmpty, "Panning discarded overlapping tiles")
        for key in shared {
          try require(
            records[key]?.samples === store.records[key]?.samples,
            "Panning recomputed a cached tile")
        }
        let beforePalette = try await gpu.readback(
          TileCompositor.snapshot(
            store: store, viewport: view, width: 512, height: 320,
            now: ProcessInfo.processInfo.systemUptime + 1))
        let computed = store.statistics.computed
        store.update(
          viewport: view, size: size, pixelWidth: 512, iterations: 200, override: nil,
          colouring: ColourSettings(palette: .fire))
        try await store.waitUntilReady()
        try require(store.statistics.computed == computed, "Changing palette recomputed samples")
        let recoloured = try await TileCompositor.snapshot(
          store: store, viewport: view, width: 512, height: 320,
          now: ProcessInfo.processInfo.systemUptime + 1)
        let colourData = try await gpu.readback(recoloured)
        try require(colourData != beforePalette, "Palette recolouring did not change output")
        // Snapshot immediately after zooming, before the worker can refine.
        view.zoom(by: 1.7, at: CGPoint(x: 256, y: 160), in: size, pixelWidth: 512)
        store.update(
          viewport: view, size: size, pixelWidth: 512, iterations: 200, override: nil,
          colouring: ColourSettings(palette: .fire))
        let fallback = try await TileCompositor.snapshot(
          store: store, viewport: view, width: 512, height: 320, sentinel: true)
        let pixels = try await gpu.readback(fallback)
        var holes = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
          if pixels[i] == 255 && pixels[i + 1] == 0 && pixels[i + 2] == 255 { holes += 1 }
        }
        try require(holes == 0, "Parent fallback left \(holes) uncovered pixels")
        try await store.waitUntilReady()
        try require(store.statistics.computed > computed, "Zoom did not refine new levels")
        // Exercise fractional zoom composition while refinement and prefetch
        // run concurrently, at a simulated 120 Hz request cadence.
        for index in 0..<40 {
          view.scale = 1.7 + Double(index) / 80
          store.update(
            viewport: view, size: size, pixelWidth: 512, iterations: 200, override: nil,
            colouring: ColourSettings(palette: .fire), zoomDirection: 1)
          _ = try await TileCompositor.snapshot(
            store: store, viewport: view, width: 512, height: 320)
          try await Task.sleep(for: .milliseconds(8))
        }
        try await store.waitUntilReady()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var report =
          try JSONSerialization.jsonObject(with: encoder.encode(store.statistics)) as! [String: Any]
        for (key, value) in cacheMetrics { report[key] = value }
        for (key, value) in deepMetrics { report[key] = value }
        print(
          String(
            decoding: try JSONSerialization.data(
              withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        print("Tile integration passed in \(elapsed) seconds")
        return 0
      } catch {
        FileHandle.standardError.write(Data(("Tile test failed: \(error)\n").utf8))
        return 1
      }
    }
  }
#endif
