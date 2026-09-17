#if os(macOS)
  import AppKit
  import Foundation
  import CoreGraphics
  import Metal

  /// Fails the process when a headless check stalls.  A main-actor worker spin
  /// would also starve any main-actor timeout, so the watchdog runs elsewhere.
  final class TileWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    init(seconds: Double, _ name: String) {
      DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
        lock.lock()
        let done = finished
        lock.unlock()
        if !done {
          FileHandle.standardError.write(Data("Tile test stalled: \(name)\n".utf8))
          exit(1)
        }
      }
    }
    func finish() {
      lock.lock()
      finished = true
      lock.unlock()
    }
  }

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
      let deepDetailBytes = deep.records.values.filter { !$0.isCoverage }.reduce(0) {
        $0 + $1.bytes
      }
      try require(
        deepDetailBytes < 20 * 1024 * 1024 && deep.residentBytes <= deep.tileResidentLimit
          && deep.coverageBytes <= deep.coverageBudgetBytes,
        "Deep detail \(deepDetailBytes), coverage \(deep.coverageBytes)/\(deep.coverageBudgetBytes), resident \(deep.residentBytes)/\(deep.tileResidentLimit) exceeded its budget"
      )
      try require(deep.grid.anchorID > 0, "Deep coordinates did not rebase")
      try require(
        deep.needed.allSatisfy { deep.records[$0] != nil }, "Deep ancestors are incomplete")
      try require(
        deep.coverage.count <= 64
          && deep.coverage.contains(where: { $0.level == deep.minimumLevel })
          && deep.coverage.filter { deep.records[$0] != nil }.count == deep.coverage.count,
        "Deep coverage pyramid was not bounded and ready")
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
    static func checkCoveragePressure() async throws {
      // This is deliberately much larger than the old 256×192 diagnostic view.
      // It leaves enough detail demand to pressure coverage, but must settle
      // without a retry spin or exceeding either reservation.
      let store = TileStore(budgetBytes: 32 * 1024 * 1024)
      let size = CGSize(width: 1_170, height: 2_532)
      let view = Viewport(
        center: CGPoint(x: -0.743643887037151, y: 0.13182590420533), scale: 128)
      func update(_ iterations: Int) {
        store.update(
          viewport: view, size: size, pixelWidth: 1_170, iterations: iterations, override: nil,
          colouring: ColourSettings())
      }
      update(200)
      try await store.waitUntilReady()
      try require(
        store.residentBytes <= store.tileResidentLimit, "Coverage exceeded resident budget")
      try require(store.coverageBytes <= store.coverageBudgetBytes, "Coverage exceeded reservation")
      let coverage = store.records.values.filter(\.isCoverage)
      try require(!coverage.isEmpty, "Pressure trace did not retain coverage")
      let samples = Dictionary(uniqueKeysWithValues: coverage.map { ($0.key, $0.samples) })
      update(4_000)
      try await store.waitUntilReady()
      for (key, texture) in samples {
        guard store.records[key]?.isCoverage == true else { continue }
        try require(
          store.records[key]?.samples === texture,
          "Coverage was extended at the visible-detail iteration limit")
      }
      try require(
        store.residentBytes <= store.tileResidentLimit, "Iteration update exceeded budget")
      store.cancel()
    }
    /// Panning through empty space must not accumulate root-level records: only
    /// the planned root footprint and a few retained cells stay protected.
    static func checkRootCoverageBounded() async throws {
      let store = TileStore(budgetBytes: 24 * 1024 * 1024)
      let size = CGSize(width: 512, height: 320)
      var view = Viewport()
      for _ in 0..<32 {
        store.update(
          viewport: view, size: size, pixelWidth: 512, iterations: 200, override: nil,
          colouring: ColourSettings())
        try await store.waitUntilReady()
        try await store.waitUntilRootCoverageReady()
        let protectedRoots = store.records.values.filter {
          $0.key.level == store.minimumLevel && $0.isCoverage
        }.count
        try require(
          protectedRoots <= store.plannedRootCount + TileStore.retainedRootLimit,
          "Root coverage accumulated \(protectedRoots) protected cells while panning")
        try require(
          store.residentBytes <= store.tileResidentLimit
            && store.coverageBytes <= store.coverageBudgetBytes,
          "Panning root coverage exceeded its budget")
        // Two view widths: a new root cell roughly every other step.
        view.pan(by: CGSize(width: -2 * size.width, height: 0), in: size)
      }
      try require(store.statistics.evictions > 0, "Root-level records were never evicted")
      try require(store.nearCoverageCount > 0, "Root cells crowded out near coverage")
      store.cancel()
    }
    /// Coverage deferred under momentary pressure must come back once memory
    /// eases, and the root must never be the coverage that yields.
    static func checkCoverageDeferralRecovers() async throws {
      var squeeze: ((TileKey) -> Void)?
      let store = TileStore(budgetBytes: 256 * 1024 * 1024) { key in squeeze?(key) }
      let size = CGSize(width: 512, height: 320)
      func update(_ center: CGPoint) {
        store.update(
          viewport: Viewport(center: center, scale: 4096), size: size, pixelWidth: 512,
          iterations: 200, override: nil, colouring: ColourSettings())
      }
      // Deep reference storage can shrink the resident limit after coverage was
      // planned.  Simulate that just as the first non-root coverage tile starts.
      squeeze = { key in
        guard store.coverage.contains(key), key.level > store.minimumLevel else { return }
        let tile = store.records.values.first?.bytes ?? 1024 * 1024
        store.diagnosticResidentLimit = store.residentBytes + tile
        squeeze = nil
      }
      update(CGPoint(x: -0.743643887037151, y: 0.13182590420533))
      try await store.waitUntilReady()
      try await store.waitUntilRootCoverageReady()
      try require(store.deferredCoverageCount > 0, "Pressure trace did not defer coverage")
      try require(
        store.residentBytes <= store.tileResidentLimit, "Deferred coverage exceeded the limit")
      // Relieve the pressure without changing demand: deferral must not outlive it.
      store.diagnosticResidentLimit = nil
      store.retryFailedWork()
      try await store.waitUntilReady()
      try require(
        store.deferredCoverageCount == 0
          && store.coverage.allSatisfy { store.records[$0] != nil },
        "Deferred coverage was not retried after memory eased")
      // Squeeze again and move to a different root cell: the root must not yield.
      store.diagnosticResidentLimit =
        store.residentBytes - 4 * (store.records.values.first?.bytes ?? 1024 * 1024)
      update(CGPoint(x: -12.9, y: 0.1))
      try await store.waitUntilReady()
      try await store.waitUntilRootCoverageReady()
      store.cancel()
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
      try require(!store.records.isEmpty, "Iteration change discarded cached detail")
      let after = try await gpu.readback(
        TileCompositor.snapshot(
          store: store, viewport: view,
          width: 256, height: 256, now: settled))
      try require(
        before == after, "Iteration change altered the picture before replacement was ready")
      update(2400)
      try require(
        store.visible.allSatisfy { store.bestAvailable(for: $0)?.key.level == $0.level },
        "Repeated invalidation lost fine coverage")
      try await store.waitUntilReady()
      try require(
        store.visible.allSatisfy { key in
          guard let record = store.records[key] else { return false }
          return record.iterations >= 2400 || record.cappedPixels == 0
        },
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
    /// Zooming out exposes coarser ancestors that have not been computed yet.
    /// The frame may fall back to the coverage pyramid, but a stand-in must not
    /// be presented at full strength while finer detail for the same cell is
    /// resident, and replacing a cell's base must fade rather than cut.
    static func checkZoomOutPresentation() async throws {
      let store = TileStore()
      let size = CGSize(width: 256, height: 192)
      let iterations = 4000
      let anchor = CGPoint(x: 128, y: 96)
      var view = Viewport()
      for _ in 0..<6 {
        view.zoom(by: 4, at: anchor, in: size, pixelWidth: 256)
        store.update(
          viewport: view, size: size, pixelWidth: 256, iterations: iterations, override: nil,
          colouring: ColourSettings(), zoomDirection: 1)
        try await store.waitUntilReady()
      }
      try require(
        store.records.values.contains { store.isPlaceholder($0) },
        "Coverage tiles were not stand-ins at a depth the view out-iterates")
      func settle() async throws {
        store.update(
          viewport: view, size: size, pixelWidth: 256, iterations: iterations, override: nil,
          colouring: ColourSettings(), zoomDirection: -1)
        try await store.waitUntilReady()
      }
      var standIns = 0
      var presented: [TileKey: TileRecord] = [:]
      var switched = 0
      for step in 0..<24 {
        view.zoom(by: 1 / 1.7, at: anchor, in: size, pixelWidth: 256)
        store.update(
          viewport: view, size: size, pixelWidth: 256, iterations: iterations, override: nil,
          colouring: ColourSettings(), zoomDirection: -1)
        // Freeze refinement so the frame under test is the one the display shows
        // in the window between the zoom and the replacement tile arriving.
        store.cancel()
        let now = ProcessInfo.processInfo.systemUptime
        let frozen = TileCompositor.plan(store: store, viewport: view, size: size, now: now)
        for cell in frozen where cell.baseIsPlaceholder {
          standIns += 1
          try require(
            !cell.fineIsGenuine || cell.uniforms.fineMix >= 1,
            "A stand-in outvoted resident detail while zooming out")
        }
        guard step % 8 == 7 else { continue }
        // Let the frozen frame's stand-ins be replaced in place, without moving
        // the view: the cells keep their keys, so their bases genuinely switch.
        for cell in frozen { presented[cell.key] = cell.base }
        try await settle()
        let after = ProcessInfo.processInfo.systemUptime
        let refined = TileCompositor.plan(store: store, viewport: view, size: size, now: after)
        for cell in refined where presented[cell.key] !== nil && presented[cell.key] !== cell.base {
          switched += 1
          try require(cell.uniforms.baseMix < 1, "A change of base cut in with no fade")
        }
        for cell in TileCompositor.plan(
          store: store, viewport: view, size: size, now: after + TilePresentation.fadeDuration)
        {
          try require(
            cell.uniforms.baseMix >= 1 || cell.coarse === cell.base,
            "A base fade did not settle")
        }
        presented.removeAll()
      }
      try require(standIns > 0, "Zoom-out never fell back to a stand-in; check is vacuous")
      try require(switched > 0, "No cell replaced its base; the fade check is vacuous")
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
      try await store.waitUntilRootCoverageReady()
      let completed = ProcessInfo.processInfo.systemUptime - start
      try require(
        store.lod > 3300 && store.records.values.filter({ !$0.isCoverage }).count <= 16,
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
      try require(
        store.statistics.preparationP95MS < 1,
        "Coverage lookup made deep compositor preparation exceed 1 ms p95")
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
      // The root coverage tile was prepared independently of the 62-level
      // ancestor walk.  A long zoom-out after a cold deep jump must therefore
      // still compose a complete frame before the new visible tiles arrive.
      view.zoom(by: pow(2, -128), at: CGPoint(x: 128, y: 96), in: size, pixelWidth: 256)
      store.update(
        viewport: view, size: size, pixelWidth: 256, iterations: 5000, override: nil,
        colouring: ColourSettings(density: 8))
      try require(
        store.visible.allSatisfy { store.bestAvailable(for: $0) != nil },
        "Coverage root was unavailable before long zoom-out composition")
      let zoomedOut = try await gpu.readback(
        TileCompositor.snapshot(
          store: store, viewport: view, width: 256, height: 192, sentinel: true))
      for i in stride(from: 0, to: zoomedOut.count, by: 4) {
        try require(
          !(zoomedOut[i] == 255 && zoomedOut[i + 1] == 0 && zoomedOut[i + 2] == 255),
          "Coverage pyramid left a long-zoom-out hole")
      }
      try await store.waitUntilReady()
      // The 20 MiB bar here predated the coverage pyramid: a deep store then held
      // only the local detail band.  It now legitimately holds a root and a
      // zoom-out ladder inside their own reservation, so assert the contract the
      // store actually makes rather than a number from before that reservation.
      try require(
        store.residentBytes <= store.tileResidentLimit,
        "Deep tile memory exceeded the store's resident limit")
      try require(
        store.coverageBytes <= store.coverageBudgetBytes,
        "Coverage exceeded its reservation at depth")
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
    /// A rotated view draws rotated quads over the same axis-aligned tiles.
    static func checkRotatedComposition(_ gpu: GPUContext) async throws {
      let size = CGSize(width: 320, height: 240)
      let store = TileStore()
      var view = Viewport(center: CGPoint(x: -0.7435, y: 0.1314), scale: 128)
      func update() {
        store.update(
          viewport: view, size: size, pixelWidth: 320, iterations: 800, override: nil,
          colouring: ColourSettings())
      }
      update()
      try await store.waitUntilReady()
      let upright = try await gpu.readback(
        TileCompositor.snapshot(
          store: store, viewport: view, width: 320, height: 240,
          now: ProcessInfo.processInfo.systemUptime + 1))
      for degrees in [30.0, 45, -75] {
        view.angle = Viewport.normalised(degrees * .pi / 180)
        update()
        try await store.waitUntilReady()
        let cells = TileCompositor.plan(store: store, viewport: view, size: size)
        try require(
          cells.count == store.visible.count,
          "A \(degrees) degree view left a cell without a tile")
        let pixels = try await gpu.readback(
          TileCompositor.snapshot(
            store: store, viewport: view, width: 320, height: 240, sentinel: true,
            now: ProcessInfo.processInfo.systemUptime + 1))
        for i in stride(from: 0, to: pixels.count, by: 4) {
          try require(
            !(pixels[i] == 255 && pixels[i + 1] == 0 && pixels[i + 2] == 255),
            "A \(degrees) degree view left a hole")
        }
        try require(Set(pixels).count > 100, "A rotated view is flat")
        try require(pixels != upright, "Rotation did not change the picture")
      }
      // Turning full circle returns the original frame.
      view.angle = 0
      update()
      try await store.waitUntilReady()
      let returned = try await gpu.readback(
        TileCompositor.snapshot(
          store: store, viewport: view, width: 320, height: 240,
          now: ProcessInfo.processInfo.systemUptime + 1))
      try require(returned == upright, "Returning to upright changed the picture")
      store.cancel()
    }
    static func percentile95(_ values: [Double]) -> Double {
      let sorted = values.sorted()
      return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    }
    /// Phone- and Mac-shaped drawables at their real budgets, swept through
    /// several levels shallow and at 1e1000.  The worker must settle, memory must
    /// stay within both limits throughout, and the whole near ladder must fit.
    static func checkRealisticCoverage() async throws -> [String: Double] {
      var metrics: [String: Double] = [:]
      // A phone at 150 MiB spends nearly all of its resident limit on a
      // full-resolution view; the detail band only guarantees the root and the
      // 2-4x zoom-out.  A Mac at 500 MiB must hold the whole near ladder.
      let devices: [(String, CGSize, Int, Int)] = [
        ("phone", CGSize(width: 1_206, height: 2_622), 150, 2),
        ("mac", CGSize(width: 3_456, height: 2_234), 500, 8),
      ]
      for (device, size, budget, guaranteed) in devices {
        let scenes: [(String, Viewport, Int)] = [
          (
            "shallow",
            try Viewport(real: "-0.743643887037151", imag: "0.13182590420533", zoom: "64"), 1000
          ),
          ("deep", try Viewport(real: "0", imag: "1", zoom: "1e1000"), 5000),
        ]
        for (scene, start, iterations) in scenes {
          let name = "\(device) \(scene)"
          let watchdog = TileWatchdog(seconds: 240, "realistic coverage, \(name)")
          defer { watchdog.finish() }
          let store = TileStore(budgetBytes: budget * 1024 * 1024)
          let begin = ProcessInfo.processInfo.systemUptime
          var view = start
          let centre = CGPoint(x: size.width / 2, y: size.height / 2)
          for _ in 0..<48 {
            view.zoom(by: 1.12, at: centre, in: size, pixelWidth: size.width)
            store.update(
              viewport: view, size: size, pixelWidth: size.width, iterations: iterations,
              override: nil, colouring: ColourSettings(), zoomDirection: 1)
            try require(
              store.residentBytes <= store.tileResidentLimit
                && store.coverageBytes <= store.coverageBudgetBytes,
              "\(name): memory exceeded its budget while zooming")
            try await Task.sleep(for: .milliseconds(8))
          }
          try await store.waitUntilReady()
          try await store.waitUntilRootCoverageReady()
          let groups = store.coverageGroups
          print(
            "Coverage \(name): capacity \(store.coverageBudgetBytes / 1_048_576) MiB, "
              + groups.map {
                "\($0.offset)→L\(store.lod.rounded(.up) - Double($0.level)):\($0.tiles)\($0.selected ? "" : "✗")"
              }
              .joined(separator: " "))
          let ladder = groups.filter { $0.offset <= guaranteed }
          try require(
            ladder.count == guaranteed && ladder.allSatisfy(\.selected)
              && store.plannedRootCount > 0,
            "\(name): the guaranteed zoom-out ladder did not fit")
          try require(
            store.residentBytes <= store.tileResidentLimit
              && store.coverageBytes <= store.coverageBudgetBytes
              && store.deferredCoverageCount == 0
              && store.coverage.allSatisfy { store.records[$0] != nil },
            "\(name): settled coverage was incomplete or over budget")
          metrics["coverage_\(device)_\(scene)_settleMS"] =
            (ProcessInfo.processInfo.systemUptime - begin) * 1000
          metrics["coverage_\(device)_\(scene)_tiles"] = Double(store.coverage.count)
          metrics["coverage_\(device)_\(scene)_nearGroups"] = Double(
            groups.filter { $0.offset <= 8 && $0.selected }.count)
          metrics["coverage_\(device)_\(scene)_sparseGroups"] = Double(
            groups.filter { $0.offset > 8 && $0.selected }.count)
          store.cancel()
        }
      }
      return metrics
    }
    /// After the pyramid is ready, moderate zoom-outs are served from each
    /// offset's planned coverage level or finer, with no uncovered cell.
    static func checkZoomOutCoverageQuality() async throws {
      let size = CGSize(width: 1_206, height: 2_622)
      let store = TileStore(budgetBytes: 150 * 1024 * 1024)
      let view = Viewport(center: CGPoint(x: -0.743643887037151, y: 0.13182590420533), scale: 65536)
      func update(_ viewport: Viewport) {
        store.update(
          viewport: viewport, size: size, pixelWidth: size.width, iterations: 1000, override: nil,
          colouring: ColourSettings())
      }
      update(view)
      try await store.waitUntilReady()
      try await store.waitUntilRootCoverageReady()
      let groups = store.coverageGroups
      for offset in [1, 2, 4] {
        guard let group = groups.first(where: { $0.offset == offset }), group.selected else {
          throw GPUFailure("Zoom-out offset \(offset) had no coverage")
        }
        var out = view
        out.zoom(
          by: pow(2, -Double(offset)), at: CGPoint(x: size.width / 2, y: size.height / 2),
          in: size, pixelWidth: size.width)
        update(out)
        store.cancel()  // Inspect the frame before any refinement arrives.
        let cells = TileCompositor.plan(store: store, viewport: out, size: size)
        try require(
          cells.count == store.visible.count, "A \(1 << offset)× zoom-out left an uncovered cell")
        let coarsest = cells.map(\.base.key.level).min() ?? .min
        try require(
          coarsest >= group.level,
          "A \(1 << offset)× zoom-out fell back to level \(coarsest), below its planned \(group.level)"
        )
        update(view)
        try await store.waitUntilReady()
      }
      store.cancel()
    }
    /// Coverage must not delay the visible view after a cold jump.  Both modes
    /// run alternately in this process, so machine speed cancels out.
    static func checkColdJumpLatency() async throws -> [String: Double] {
      let size = CGSize(width: 1_024, height: 768)
      var metrics: [String: Double] = [:]
      for (label, zoom) in [("1e100", "1e100"), ("1e1000", "1e1000")] {
        let view = try Viewport(real: "0", imag: "1", zoom: zoom)
        var best: [Bool: Double] = [:]
        for round in 0..<4 {
          let enabled = round % 2 == 1
          let store = TileStore(budgetBytes: 500 * 1024 * 1024)
          store.coverageEnabled = enabled
          let start = ProcessInfo.processInfo.systemUptime
          store.update(
            viewport: view, size: size, pixelWidth: size.width, iterations: 5000, override: nil,
            colouring: ColourSettings())
          while !store.allVisibleReady {
            if let error = store.error { throw GPUFailure(error) }
            try await Task.sleep(for: .milliseconds(1))
          }
          let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
          best[enabled] = min(best[enabled] ?? .infinity, ms)
          store.cancel()
        }
        let off = best[false]!
        let on = best[true]!
        print("Cold jump \(label): visible ready \(on) ms with coverage, \(off) ms without")
        metrics["coldVisible\(label)CoverageMS"] = on
        metrics["coldVisible\(label)NoCoverageMS"] = off
        try require(
          on <= off * 1.25 + 30, "Coverage delayed the visible view after a cold jump to \(label)")
      }
      return metrics
    }
    /// Main-thread cost while moving at 1e1000: demand updates and frame plans
    /// interleaved with a running worker, as the display drives them.
    static func checkMovingPreparation() async throws -> [String: Double] {
      let size = CGSize(width: 1_024, height: 768)
      let store = TileStore(budgetBytes: 500 * 1024 * 1024)
      var view = try Viewport(real: "0", imag: "1", zoom: "1e1000")
      func update(_ direction: Int) {
        store.update(
          viewport: view, size: size, pixelWidth: size.width, iterations: 5000, override: nil,
          colouring: ColourSettings(), zoomDirection: direction)
      }
      update(0)
      try await store.waitUntilReady()
      var updates: [Double] = []
      var plans: [Double] = []
      for frame in 0..<120 {
        let zooming = frame % 60 < 30
        if zooming {
          view.zoom(
            by: frame % 120 < 60 ? 1.04 : 1 / 1.04, at: CGPoint(x: 400, y: 300), in: size,
            pixelWidth: size.width)
        } else {
          view.pan(by: CGSize(width: 6, height: 3), in: size)
        }
        var start = ProcessInfo.processInfo.systemUptime
        update(zooming ? 1 : 0)
        updates.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        start = ProcessInfo.processInfo.systemUptime
        _ = TileCompositor.plan(store: store, viewport: view, size: size)
        plans.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        try await Task.sleep(for: .milliseconds(8))
      }
      store.cancel()
      let updateP95 = percentile95(updates)
      let planP95 = percentile95(plans)
      print("Moving at 1e1000: update p95 \(updateP95) ms, frame plan p95 \(planP95) ms")
      try require(updateP95 < 4, "Demand updates exceeded 4 ms p95 while moving at 1e1000")
      try require(planP95 < 2, "Frame plans exceeded 2 ms p95 while moving at 1e1000")
      return ["movingUpdateP95MS": updateP95, "movingPlanP95MS": planP95]
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
        try await checkIterationReuse(gpu)
        try await checkObservedCeiling(gpu)
        try await checkNavigationRoundTrip()
        try await checkRotationAndBounds()
        try await checkLocations()
        try await checkRotatedComposition(gpu)
        try await checkStreamedReferences(gpu)
        try await checkResumption(gpu)
        try await checkMipmaps(gpu)
        let cacheMetrics = try await checkCache()
        try await checkCoveragePressure()
        try await checkRootCoverageBounded()
        try await checkCoverageDeferralRecovers()
        try await checkZoomOutPresentation()
        var deepMetrics = try await checkDeepTiles(gpu)
        try await checkZoomOutCoverageQuality()
        for source in [
          try await checkRealisticCoverage(), try await checkColdJumpLatency(),
          try await checkMovingPreparation(),
        ] {
          deepMetrics.merge(source) { _, new in new }
        }
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
