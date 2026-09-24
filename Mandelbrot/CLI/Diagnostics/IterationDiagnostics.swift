#if os(macOS)
  import Foundation
  import CoreGraphics
  import Metal

  extension TileDiagnostics {
    static func checkIterationReuse(_ gpu: GPUContext) async throws {
      let view = Viewport()
      let size = CGSize(width: 256, height: 192)
      let store = TileStore()
      func update(_ store: TileStore, _ limit: Int) {
        store.update(
          viewport: view, size: size, pixelWidth: 256, iterations: limit,
          override: .metalDouble, colouring: ColourSettings())
      }
      update(store, 400)
      try await store.waitUntilReady()
      let old = store.records
      let sampled = store.statistics.sampledPixels
      // The compositor marks counts at or above the limit as capped as it
      // draws, so a lower limit changes no record: it must draw exactly as a
      // fresh render at that limit does.
      try require(
        (Array(store.records.values) + store.fallback).contains { $0.maximumEscaped >= 100 },
        "The decrease check found nothing that could change")
      update(store, 100)
      try await store.waitUntilReady()
      try require(store.statistics.sampledPixels == sampled, "Decreasing limit recomputed samples")
      for (key, record) in old {
        try require(store.records[key] === record, "Decrease discarded a cached record")
      }
      let fresh = TileStore()
      update(fresh, 100)
      try await fresh.waitUntilReady()
      let a = try await gpu.readback(
        TileCompositor.snapshot(
          store: store, viewport: view, width: 256, height: 192,
          now: ProcessInfo.processInfo.systemUptime + 1))
      let b = try await gpu.readback(
        TileCompositor.snapshot(
          store: fresh, viewport: view, width: 256, height: 192,
          now: ProcessInfo.processInfo.systemUptime + 1))
      try require(a == b, "A lower cap draws differently from a fresh render")
      update(store, 400)
      try await store.waitUntilReady()
      try require(
        store.statistics.sampledPixels == sampled, "Returning to cached limit recomputed samples")
      var before: [TileKey: Data] = [:]
      for (key, record) in store.records { before[key] = try await gpu.readback(record.samples) }
      let expected = store.needed.reduce(0) { total, key in
        guard let record = store.records[key], !record.isCoverage else { return total }
        return total + record.cappedPixels
      }
      update(store, 800)
      try await store.waitUntilReady()
      let raisedFresh = TileStore()
      update(raisedFresh, 800)
      try await raisedFresh.waitUntilReady()
      // Extended records replace their old-limit versions with a fade that starts
      // when a frame first presents them; present once, then compare settled.
      _ = try await TileCompositor.snapshot(
        store: store, viewport: view, width: 256, height: 192,
        now: ProcessInfo.processInfo.systemUptime + 1)
      let raised = try await gpu.readback(
        TileCompositor.snapshot(
          store: store, viewport: view, width: 256, height: 192,
          now: ProcessInfo.processInfo.systemUptime + 5))
      let raisedExpected = try await gpu.readback(
        TileCompositor.snapshot(
          store: raisedFresh, viewport: view, width: 256, height: 192,
          now: ProcessInfo.processInfo.systemUptime + 1))
      try require(
        raised == raisedExpected, "A raised limit draws differently from a fresh render")
      try require(
        expected > 0 && store.statistics.sampledPixels - sampled == expected,
        "Increase recomputed already escaped pixels, or extended nothing")
      for (key, data) in before {
        guard let record = store.records[key] else { continue }
        let next = try await gpu.readback(record.samples)
        for offset in stride(from: 0, to: data.count, by: 8) {
          let n = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
          if n < SampleRecord.glitched {
            try require(
              data[offset..<offset + 8] == next[offset..<offset + 8],
              "Escaped sample changed during extension")
          }
        }
      }
      print(
        "Iteration reuse: decrease/return sampled zero pixels; increase sampled \(expected) capped pixels"
      )
      // A tile with no capped pixels is exact at any higher limit, so it is
      // neither re-sampled nor treated as a stand-in after a raise.
      let outside = TileStore()
      let far = Viewport(center: CGPoint(x: 7, y: 7), scale: 4)
      for limit in [200, 400] {
        outside.update(
          viewport: far, size: size, pixelWidth: 256, iterations: limit, override: .metalDouble,
          colouring: ColourSettings())
        try await outside.waitUntilReady()
      }
      let escaped = outside.visible.compactMap { outside.records[$0] }
      try require(
        !escaped.isEmpty && escaped.allSatisfy { $0.iterations == 200 && $0.cappedPixels == 0 },
        "Escaped-only tiles were re-sampled after a raise")
      try require(
        !escaped.contains { outside.isPlaceholder($0) },
        "Escaped-only tiles became permanent stand-ins after a raise")
    }
    /// Settles a headless model the way the display drives it: tile demand at
    /// the model's current limit, then time for a deferred decrease.
    static func settleDepth(_ model: ExplorerModel, size: CGSize) async throws {
      var stable = 0
      var last = -1
      for _ in 0..<40 {
        model.tiles.update(
          viewport: model.viewport, size: size, pixelWidth: size.width,
          iterations: model.iterations, override: model.rendererOverride,
          colouring: model.colouring)
        try await model.tiles.waitUntilReady()
        try await Task.sleep(for: .milliseconds(360))
        stable = model.iterations == last ? stable + 1 : 0
        last = model.iterations
        if stable >= 2 { return }
      }
      throw GPUFailure("Automatic depth never settled")
    }
    /// The lowering half of 2.3: a settled view lowers the limit to twice its
    /// highest escaped count, exactly, and new content with higher counts
    /// releases the ceiling.
    static func checkObservedCeiling(_ gpu: GPUContext) async throws {
      let size = CGSize(width: 256, height: 192)
      let model = ExplorerModel()
      model.viewport = try Viewport(real: "0", imag: "1", zoom: "1e1000")
      let estimate = model.iterations
      try await settleDepth(model, size: size)
      guard let maximum = model.tiles.visibleMaximumEscaped, let ceiling = model.ceiling else {
        throw GPUFailure("A settled deep view did not observe a ceiling")
      }
      try require(
        model.iterations == IterationPolicy.rounded(Double(2 * maximum))
          && model.iterations * 4 <= estimate,
        "Observed ceiling \(ceiling.base) did not lower \(estimate) to twice \(maximum)")
      let fresh = TileStore()
      fresh.update(
        viewport: model.viewport, size: size, pixelWidth: size.width, iterations: model.iterations,
        override: nil, colouring: model.colouring)
      try await fresh.waitUntilReady()
      let lowered = try await gpu.readback(
        TileCompositor.snapshot(
          store: model.tiles, viewport: model.viewport, width: 256, height: 192,
          now: ProcessInfo.processInfo.systemUptime + 1))
      let expected = try await gpu.readback(
        TileCompositor.snapshot(
          store: fresh, viewport: model.viewport, width: 256, height: 192,
          now: ProcessInfo.processInfo.systemUptime + 1))
      let difference = zip(lowered, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0
      try require(difference <= 2, "Lowering changed the picture (\(difference)/255)")
      print(
        "Observed ceiling at 1e1000: \(estimate) → \(model.iterations) (highest escaped \(maximum)); picture difference \(difference)/255"
      )
      model.setActive(false)
      fresh.cancel()

      // Shallow: empty space lowers to the minimum; the seahorse valley's counts
      // reach that limit and must release it.
      let shallow = ExplorerModel()
      shallow.viewport = Viewport(center: CGPoint(x: -2.2, y: 1.2), scale: 1024)
      try await settleDepth(shallow, size: size)
      try require(
        shallow.ceiling != nil && shallow.iterations == IterationPolicy.minimum,
        "Empty space did not lower the limit to the minimum")
      shallow.viewport = Viewport(
        center: CGPoint(x: -0.743643887037151, y: 0.13182590420533), scale: 1024)
      try await settleDepth(shallow, size: size)
      try require(
        shallow.iterations > IterationPolicy.minimum,
        "Higher counts in new content did not release the observed ceiling")
      shallow.setActive(false)
    }
  }
#endif
