#if os(macOS)
  import Foundation
  import CoreGraphics

  extension TileDiagnostics {
    static func checkNavigationRoundTrip() async throws {
      let size = CGSize(width: 32, height: 24)
      let store = TileStore()
      let fresh = TileStore()
      let shallow = Viewport(center: CGPoint(x: 3, y: 0))
      func update(_ store: TileStore, _ view: Viewport, _ iterations: Int = 200) {
        store.update(
          viewport: view, size: size, pixelWidth: 32, iterations: iterations,
          override: nil, colouring: ColourSettings())
      }
      update(fresh, shallow)
      try await fresh.waitUntilReady()
      for zoom in ["1e12", "1e1000"] {
        update(store, try Viewport(real: "3", imag: "0", zoom: zoom))
        try await store.waitUntilReady()
        try require(store.grid.deepAnchor != nil, "Round trip did not exercise a deep anchor")
        let before = store.statistics.computed
        update(store, shallow)
        try await store.waitUntilReady()
        let referenceBytes = await store.perturbationResources.references.bytes
        try require(referenceBytes == 0, "Shallow return retained deep reference storage")
        try require(store.grid.deepAnchor == nil, "Deep anchor survived shallow navigation")
        try require(
          store.statistics.computed - before <= fresh.statistics.computed,
          "Returning shallow computed more tiles than a fresh view")
        try require(
          store.records.values.allSatisfy { $0.bounds.deepOrigin == nil },
          "Shallow tiles retained high-precision bounds")
        var worst = 0.0
        for i in 0..<120 {
          var v = shallow
          v.center.x += Double(i % 2) * 0.0001
          update(store, v)
          worst = max(worst, store.statistics.updateMS)
        }
        try await store.waitUntilReady()
        print(
          "Shallow return from \(zoom): \(store.statistics.computed-before) tiles; anchor demoted; update max \(worst) ms"
        )
      }
      // Same navigation, with and without automatic limits. Outside-set pixels
      // should never be resampled just because the automatic limit rises.
      var totals: [Int] = []
      for automatic in [false, true] {
        let trace = TileStore()
        var limit = 200
        for step in Array(0...100) + Array((0..<100).reversed()) {
          let view = try Viewport(real: "3", imag: "0", zoom: String(pow(2, Double(step))))
          if automatic {
            let target = IterationPolicy.estimate(logScale: view.logScale)
            if IterationPolicy.shouldRaise(current: limit, target: target)
              || IterationPolicy.shouldLower(current: limit, target: target)
            {
              limit = target
            }
          }
          update(trace, view, limit)
          try await trace.waitUntilReady()
        }
        totals.append(trace.statistics.sampledPixels)
      }
      try require(
        totals[1] <= totals[0] + 12 * 258 * 258,
        "Automatic limits caused excess sampling on the zoom round trip")
      print("1x–1e30 round trip sampled pixels: fixed \(totals[0]), automatic \(totals[1])")
    }
  }
#endif
