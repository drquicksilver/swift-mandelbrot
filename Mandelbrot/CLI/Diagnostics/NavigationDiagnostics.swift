// `--test-tiles` checks for navigation through `ExplorerModel`, as the UI drives
// it: redraw routing, the resting scale, links and history, rotation and gentle
// bounds, and a long zoom there and back.

#if os(macOS)
  import Foundation
  import CoreGraphics

  extension TileDiagnostics {
    /// Every redraw request goes through one call, and the springs use it as
    /// their own clock.  The canvas answers `onRedrawNeeded` by unpausing and
    /// marking the layer dirty; here a counter stands in for the layer.
    static func checkRedrawRouting() async throws {
      let model = ExplorerModel()
      model.resize(CGSize(width: 800, height: 500), displayScale: 2)
      var redraws = 0
      model.onRedrawNeeded = { redraws += 1 }

      // Tile completion, which is the case that left the screen stale: the work
      // finishes with no viewport change to make some other view redraw.
      redraws = 0
      model.tiles.update(
        viewport: model.viewport, size: model.size, pixelWidth: model.pixelWidth,
        iterations: model.iterations, override: nil, colouring: model.colouring)
      try await model.tiles.waitUntilReady()
      try require(redraws > 0, "Tile completion did not ask for a frame")

      // A palette change draws the same tiles in new colours.
      redraws = 0
      model.colouring = ColourSettings(palette: .fire)
      try require(redraws > 0, "Changing the palette did not ask for a frame")

      // Jumping to a bookmark: one viewport change, then silence.
      redraws = 0
      model.apply(Location.gallery[1])
      try require(redraws > 0, "Moving to a location did not ask for a frame")

      // The gentle bounds spring, driven by nothing but the frames it asks for.
      model.stopMotion()
      model.viewport = Viewport(center: CGPoint(x: 40, y: 25), scale: 8)
      model.interactionActive = true
      var pending = false
      model.onRedrawNeeded = { pending = true }
      model.interactionActive = false
      try require(model.isAnimating, "Letting go outside the bounds started no spring")
      try require(pending, "Ending the interaction did not ask for the spring's first frame")
      var frames = 0
      var now = ProcessInfo.processInfo.systemUptime
      while pending, frames < 1200 {
        pending = false
        now += 1 / 120.0
        model.advanceMotion(now: now)
        frames += 1
      }
      try require(frames > 1, "The spring ran for one frame and then asked for no more")
      try require(!model.isAnimating, "The spring stopped asking for frames before it settled")
      let bounded = model.viewport.boundedCenter(size: model.size)
      try require(
        hypot(model.viewport.center.x - bounded.x, model.viewport.center.y - bounded.y)
          < model.viewport.span * 1e-3,
        "The self-driven spring left the set off screen")
      model.setActive(false)
    }
    /// The resting scale follows the window: the whole set has to fit both
    /// dimensions, and the spring has to be allowed to go far enough out to show
    /// it.  A constant resting scale cropped the set on anything wider than 5:4.
    static func checkRestingScale() async throws {
      for size in [
        CGSize(width: 500, height: 900),  // portrait
        CGSize(width: 700, height: 700),  // square
        CGSize(width: 1600, height: 900),  // landscape
        CGSize(width: 2400, height: 800),  // very wide
      ] {
        let model = ExplorerModel()
        model.resize(size, displayScale: 2)
        // Start further out than the spring allows, so it settles at the rest.
        model.viewport.zoom(
          by: 0.02, at: CGPoint(x: size.width / 2, y: size.height / 2), in: size,
          pixelWidth: model.pixelWidth)
        var now = ProcessInfo.processInfo.systemUptime
        for _ in 0..<600 {
          now += 1 / 120
          model.advanceMotion(now: now)
        }
        let view = model.viewport
        try require(
          abs(view.logScale - Viewport.restingLogScale(size: size)) < 1e-3,
          "\(size) did not settle at its resting scale")
        // The view is wide enough for the set's bounds in both dimensions, and no
        // wider than one of them needs: the tighter dimension is snug.
        let visible = (x: view.span, y: view.span * size.height / size.width)
        let slack = (
          x: visible.x / Viewport.setBounds.width, y: visible.y / Viewport.setBounds.height
        )
        try require(
          slack.x > 1 - 1e-6 && slack.y > 1 - 1e-6,
          "\(size) rested with the set cropped: \(slack.x)x by \(slack.y)x")
        try require(
          min(slack.x, slack.y) < 1.02, "\(size) rested further out than the set needed")
        // And the set itself, not just the padded bounds, is on screen at the
        // view the app opens with.
        for corner in [
          CGPoint(x: -2, y: -1.13), CGPoint(x: 0.25, y: 1.13), CGPoint(x: -2, y: 1.13),
          CGPoint(x: 0.25, y: -1.13),
        ] {
          let point = view.screen(for: corner, in: size)
          try require(
            point.x > -1 && point.x < size.width + 1 && point.y > -1
              && point.y < size.height + 1,
            "\(size) cut off the set at \(corner): \(point)")
        }
        model.setActive(false)
      }
    }
    /// Locations, history and bookmarks, driven through the model the UI uses.
    static func checkLocations() async throws {
      let defaults = UserDefaults(suiteName: "MandelbrotDiagnostics")!
      defaults.removeObject(forKey: "DiagnosticBookmarks")
      let store = LocationStore(defaults: defaults, key: "DiagnosticBookmarks")
      let model = ExplorerModel(bookmarks: store)
      model.resize(CGSize(width: 800, height: 500), displayScale: 2)

      // Opening a shared link moves the view, its rotation, palette and detail:
      // a deep one, with a fixed limit and a palette of its own.
      let deep = Location(
        real: "-0.743643887037158704752191506114774",
        imag: "0.131825904205311970493132056385139", scale: "1e100", iterations: 60_000,
        palette: .ink, density: 512)
      model.open(deep.url)
      try require(model.locationError == nil, "A deep link failed to open")
      let deepView = try deep.viewport()
      try require(
        abs(model.viewport.logScale - deepView.logScale) < 1e-9
          && model.colouring == deep.colouring && !model.automaticIterations
          && model.iterations == 60_000,
        "A link did not restore the view it described")
      // A bad link reports itself and leaves the view alone.
      let before = model.viewport
      model.open(URL(string: "mandelbrot://view?re=0&im=0")!)
      try require(
        model.locationError != nil && model.viewport == before,
        "A malformed link was not reported, or moved the view")

      // History records settled views and steps back and forward.
      model.apply(Location.gallery[0])
      try require(model.automaticIterations, "A gallery location did not restore automatic depth")
      let whole = model.viewport
      model.apply(Location.gallery[1])
      let second = try Location.gallery[1].viewport()
      try require(
        model.canGoBack && !model.canGoForward, "Applying a location did not record history")
      model.goBack()
      try require(
        model.viewport == whole && model.canGoForward,
        "Back did not return to the previous settled view")
      model.goForward()
      try require(
        abs(model.viewport.logScale - second.logScale) < 1e-9,
        "Forward did not return to the newer view")
      // Small moves do not fill the history; a big one does.
      let depth = model.viewport.logScale
      model.pan(CGSize(width: 4, height: 0))
      model.recordHistory()
      try require(
        abs(model.viewport.logScale - depth) < 1e-9 && !model.canGoForward,
        "A nudge cleared the forward history")
      let steps = model.canGoBack
      model.zoom(64, at: CGPoint(x: 400, y: 250))
      model.recordHistory()
      try require(model.canGoBack && steps, "A large zoom was not recorded")

      // Ordinary navigation is history too: keyboard zooming settles at once,
      // and jumping away has to record the view being left, not the last one
      // that happened to settle onto the record.
      let keyboard = ExplorerModel(bookmarks: store)
      keyboard.resize(CGSize(width: 800, height: 500), displayScale: 2)
      for _ in 0..<5 { keyboard.perform(.zoomIn) }
      let zoomed = keyboard.viewport
      try require(
        abs(zoomed.logScale - 5) < 1e-9 && keyboard.canGoBack,
        "Keyboard zooming did not reach 32x, or recorded no history")
      keyboard.apply(Location.gallery[0])
      keyboard.goBack()
      try require(
        abs(keyboard.viewport.logScale - zoomed.logScale) < 1e-9,
        "Back did not return to the view the jump departed from")
      // Leaving home is recorded, so the first jump of a session can come back.
      let fresh = ExplorerModel(bookmarks: store)
      fresh.resize(CGSize(width: 800, height: 500), displayScale: 2)
      let home = fresh.viewport
      // Not gallery[0]: that is the home view itself, and going nowhere records
      // nothing.
      fresh.apply(Location.gallery[1])
      try require(fresh.canGoBack, "The first jump of a session left Back unavailable")
      fresh.goBack()
      try require(fresh.viewport == home, "Back from the first jump did not reach home")
      // The record carries the settings the departing view was seen under.
      let manual = ExplorerModel(bookmarks: store)
      manual.resize(CGSize(width: 800, height: 500), displayScale: 2)
      manual.automaticIterations = false
      manual.manualIterations = 1234
      manual.apply(Location.gallery[1])
      manual.goBack()
      try require(
        !manual.automaticIterations && manual.iterations == 1234,
        "Back did not restore the detail the departing view was seen with")
      keyboard.setActive(false)
      fresh.setActive(false)
      manual.setActive(false)

      // Bookmarks persist, rename and delete.
      model.bookmarkCurrentView(named: "Test spot")
      try require(store.bookmarks.first?.name == "Test spot", "Bookmarking did not store the view")
      let reloaded = LocationStore(defaults: defaults, key: "DiagnosticBookmarks")
      try require(
        reloaded.bookmarks.count == 1 && reloaded.bookmarks[0].real == store.bookmarks[0].real,
        "Bookmarks did not survive a reload")
      store.rename(store.bookmarks[0], to: "Renamed")
      try require(
        LocationStore(defaults: defaults, key: "DiagnosticBookmarks").bookmarks[0].name
          == "Renamed", "Renaming a bookmark did not persist")
      store.remove(store.bookmarks[0])
      try require(
        LocationStore(defaults: defaults, key: "DiagnosticBookmarks").bookmarks.isEmpty,
        "Removing a bookmark did not persist")
      defaults.removeObject(forKey: "DiagnosticBookmarks")
      model.setActive(false)
    }
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
      // A pinch ignores its first ten degrees, then rotates one to one, and
      // reports what it applied so that only that much can be flung.
      try require(
        model.applyTwist(5 * .pi / 180, at: CGPoint(x: 400, y: 250)) == 0,
        "A suppressed twist claimed to have rotated the view")
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
      try require(
        model.rotationTarget == 0 && model.isAnimating, "A near-upright twist did not snap")
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
      try require(
        !model.isAnimating && model.viewport.angle != 0, "Rotation inertia did not settle")
      model.perform(.resetRotation)
      run(model, 2)
      // The whole touch sequence: a twist small enough to be ignored, then the
      // fingers lift.  Flinging the raw finger movement would tilt a view the
      // gesture deliberately left alone.
      let lift = ExplorerModel()
      lift.resize(CGSize(width: 800, height: 500), displayScale: 2)
      let anchor = CGPoint(x: 400, y: 250)
      var applied = 0.0
      for _ in 0..<5 { applied += lift.applyTwist(1 * .pi / 180, at: anchor) }
      lift.endTwist(at: anchor)
      lift.fling(rotation: applied / (5 / 60.0), anchor: anchor)
      run(lift, 3)
      try require(
        lift.viewport.angle == 0,
        "A 5 degree twist under the threshold still tilted the view on release")
      // And a snap decided on release is not undone by the fling that follows.
      lift.applyTwist((10 + 2) * .pi / 180, at: anchor)
      lift.endTwist(at: anchor)
      try require(lift.rotationTarget == 0, "A near-upright twist did not snap")
      lift.fling(rotation: 6, anchor: anchor)
      // The spring wins in the end either way, so watch the journey: a fling
      // that survives the snap throws the view away from upright first.
      var worst = 0.0
      var clock = ProcessInfo.processInfo.systemUptime
      for _ in 0..<180 {
        clock += 1 / 60
        lift.advanceMotion(now: clock)
        worst = max(worst, abs(lift.viewport.angle))
      }
      try require(
        worst < 2.1 * .pi / 180,
        "A fling on release threw the snapping view \(worst * 180 / .pi) degrees off upright")
      try require(
        lift.viewport.angle == 0 && !lift.isAnimating,
        "The snap back to upright did not settle")
      lift.setActive(false)

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
        out.viewport.logScale <= Viewport.minimumLogScale(size: out.size) + 1e-9,
        "Zooming out did not reach the furthest scale")
      var now = ProcessInfo.processInfo.systemUptime
      for _ in 0..<180 {
        now += 1 / 60
        out.advanceMotion(now: now)
      }
      try require(
        abs(out.viewport.logScale - Viewport.restingLogScale(size: out.size)) < 1e-3,
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
