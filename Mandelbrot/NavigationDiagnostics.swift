#if os(macOS)
  import Foundation
  import CoreGraphics

  extension TileDiagnostics {
    /// Rotation, snapping, the compass and the gentle bounds all animate through
    /// `advanceMotion`, so they are driven here exactly as the display drives them.
    static func checkRotationAndBounds() async throws {
      let model = ExplorerModel()
      model.resize(CGSize(width: 800, height: 500), displayScale: 2)
      func run(_ target: ExplorerModel, _ seconds: Double, hz: Double = 60) {
        var now = ProcessInfo.processInfo.systemUptime
        for _ in 0..<Int(seconds * hz) {
          now += 1 / hz
          target.advanceMotion(now: now)
        }
      }
      // A pinch ignores its first ten degrees, then rotates one to one.
      model.applyTwist(5 * .pi / 180, at: CGPoint(x: 400, y: 250))
      try require(model.viewport.angle == 0, "A small twist tilted the view")
      model.applyTwist(20 * .pi / 180, at: CGPoint(x: 400, y: 250))
      try require(
        abs(model.viewport.angle - 15 * .pi / 180) < 1e-9,
        "Twisting past the threshold did not rotate one to one")
      // Ending a twist near upright snaps back, and the snap animates.
      model.endTwist()
      try require(model.rotationTarget == nil, "A 15 degree tilt was snapped away")
      model.rotate(-13 * .pi / 180)
      model.endTwist()
      try require(model.rotationTarget == 0 && model.isAnimating, "A near-upright twist did not snap")
      run(model, 1)
      try require(
        model.viewport.angle == 0 && model.rotationTarget == nil,
        "The snap did not settle exactly upright")
      // Beyond three degrees it stays where the fingers left it.
      model.applyTwist((10 + 30) * .pi / 180, at: CGPoint(x: 400, y: 250))
      model.endTwist()
      try require(
        model.rotationTarget == nil && abs(model.viewport.angle - 30 * .pi / 180) < 1e-9,
        "A deliberate rotation was snapped away")
      // The compass animates back to upright, and rotation inertia decays.
      model.resetRotation()
      run(model, 2)
      try require(model.viewport.angle == 0, "The compass did not return the view to upright")
      model.fling(rotation: 3)
      try require(model.isAnimating, "A rotation fling did not animate")
      run(model, 3)
      try require(!model.isAnimating && model.viewport.angle != 0, "Rotation inertia did not settle")
      model.perform(.resetRotation)
      run(model, 2)

      // Gentle bounds: panning into empty space springs back until part of the
      // set is in view, from the same analytic model as inertia.
      func settleBounds(hz: Double) -> Viewport {
        let fresh = ExplorerModel()
        fresh.resize(CGSize(width: 800, height: 500), displayScale: 2)
        fresh.viewport = Viewport(center: CGPoint(x: 40, y: 25), scale: 8)
        try? require(fresh.boundsNeeded, "Empty space did not ask for a spring")
        var now = ProcessInfo.processInfo.systemUptime
        for _ in 0..<Int(3 * hz) {
          now += 1 / hz
          fresh.advanceMotion(now: now)
        }
        return fresh.viewport
      }
      let slow = settleBounds(hz: 60)
      let fast = settleBounds(hz: 120)
      try require(
        !slow.center.x.isNaN && abs(slow.center.x - fast.center.x) < 1e-6
          && abs(slow.center.y - fast.center.y) < 1e-6,
        "The bounds spring depends on the refresh rate")
      let bounded = slow.boundedCenter(size: CGSize(width: 800, height: 500))
      try require(
        hypot(slow.center.x - bounded.x, slow.center.y - bounded.y) < slow.span * 1e-3,
        "The bounds spring left the set off screen")
      // Zooming out past the whole set returns to it.
      let out = ExplorerModel()
      out.resize(CGSize(width: 800, height: 500), displayScale: 2)
      out.viewport.zoom(
        by: 0.25, at: CGPoint(x: 400, y: 250), in: out.size, pixelWidth: out.pixelWidth)
      try require(
        out.viewport.logScale <= Viewport.minimumLogScale + 1e-9,
        "Zooming out did not reach the furthest scale")
      var now = ProcessInfo.processInfo.systemUptime
      for _ in 0..<180 {
        now += 1 / 60
        out.advanceMotion(now: now)
      }
      try require(
        abs(out.viewport.logScale - Viewport.restingLogScale) < 1e-3,
        "Zooming out past the set did not spring back to it")
      // The precision limit bounces rather than stopping dead.
      let deep = ExplorerModel()
      deep.resize(CGSize(width: 800, height: 500), displayScale: 2)
      deep.viewport = try Viewport(real: "0", imag: "1", zoom: "1e3913")
      deep.fling(zoom: 4)
      // Enough travel to reach the cap within one fling; `fling` itself clamps.
      deep.motion.zoomVelocity = 20
      run(deep, 0.5)
      // The kick is still unwinding: the view sits just inside the cap, moving
      // outwards, instead of resting against it with no velocity.
      try require(
        deep.motion.zoomVelocity < 0
          && deep.viewport.logScale < Viewport.maximumLogScale
          && deep.viewport.logScale > Viewport.maximumLogScale - 1.5,
        "Reaching the precision limit stopped dead instead of bouncing")
      model.setActive(false)
      out.setActive(false)
      deep.setActive(false)
    }
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
        totals.append(trace.statistics.sampledPixels - trace.statistics.coverageSampledPixels)
      }
      try require(
        totals[1] <= totals[0] + 64 * 258 * 258,
        "Automatic limits caused excess sampling on the zoom round trip")
      print("1x–1e30 round trip sampled pixels: fixed \(totals[0]), automatic \(totals[1])")
    }
  }
#endif
