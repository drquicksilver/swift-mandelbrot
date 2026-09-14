#if os(macOS)
  import Foundation
  import CoreGraphics
  import Metal

  extension TileDiagnostics {
    static func checkIterationReuse(_ gpu: GPUContext) async throws {
      let view = Viewport()
      let size = CGSize(width: 64, height: 48)
      let store = TileStore()
      func update(_ store: TileStore, _ limit: Int) {
        store.update(
          viewport: view, size: size, pixelWidth: 64, iterations: limit,
          override: .metalDouble, colouring: ColourSettings())
      }
      update(store, 400)
      try await store.waitUntilReady()
      let old = store.records
      let sampled = store.statistics.sampledPixels
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
          store: store, viewport: view, width: 64, height: 48,
          now: ProcessInfo.processInfo.systemUptime + 1))
      let b = try await gpu.readback(
        TileCompositor.snapshot(
          store: fresh, viewport: view, width: 64, height: 48,
          now: ProcessInfo.processInfo.systemUptime + 1))
      try require(a == b, "Recolouring at a lower cap differs from a fresh render")
      update(store, 400)
      try await store.waitUntilReady()
      try require(
        store.statistics.sampledPixels == sampled, "Returning to cached limit recomputed samples")
      var before: [TileKey: Data] = [:]
      for (key, record) in store.records { before[key] = try await gpu.readback(record.samples) }
      let expected = store.needed.reduce(0) { $0 + (store.records[$1]?.cappedPixels ?? 0) }
      update(store, 800)
      try await store.waitUntilReady()
      try require(
        store.statistics.sampledPixels - sampled == expected,
        "Increase recomputed already escaped pixels")
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
    }
  }
#endif
