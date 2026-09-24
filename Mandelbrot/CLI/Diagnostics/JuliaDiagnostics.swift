// `--test-tiles` checks for the Julia companion, against the mathematics and
// through the panel's own gestures and redraws.

#if os(macOS)
  import CoreGraphics
  import Foundation
  import Metal
  import MetalKit

  extension TileDiagnostics {
    /// Checks the companion against the mathematics rather than against itself:
    /// for c = 0 the Julia set is exactly the closed unit disc, and for c = -1
    /// the critical point is periodic, so 0 never escapes.
    static func checkJuliaCompanion(_ gpu: GPUContext) async throws {
      let size = 128
      let samples = try gpu.texture(width: size, height: size, format: .rg32Uint)
      let view = Viewport(center: .zero, scale: 1)
      _ = try await gpu.julia(into: samples, viewport: view, c: .zero, iterations: 2000)
      let disc = try await gpu.readback(samples)
      var inside = 0
      var outside = 0
      for y in 0..<size {
        for x in 0..<size {
          let offset = (y * size + x) * 8
          let n = disc.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
          }
          let span = view.span
          let zx = view.center.x - span / 2 + (Double(x) + 0.5) * span / Double(size)
          let zy = view.center.y + span / 2 - (Double(y) + 0.5) * span / Double(size)
          let radius = hypot(zx, zy)
          if radius < 0.98 {
            inside += 1
            try require(n == SampleRecord.capped, "c = 0: |z| = \(radius) should never escape")
          } else if radius > 1.02 {
            outside += 1
            try require(n != SampleRecord.capped, "c = 0: |z| = \(radius) should escape")
          }
        }
      }
      try require(inside > 1000 && outside > 1000, "The unit-disc check sampled too little")
      func sample(_ data: Data, _ x: Int, _ y: Int) -> UInt32 {
        data.withUnsafeBytes {
          $0.loadUnaligned(fromByteOffset: (y * size + x) * 8, as: UInt32.self)
        }
      }
      // c = -1: zero is periodic, and a point well outside the set escapes fast.
      _ = try await gpu.julia(
        into: samples, viewport: Viewport(center: .zero, scale: 1), c: CGPoint(x: -1, y: 0),
        iterations: 2000)
      let rabbit = try await gpu.readback(samples)
      try require(
        sample(rabbit, size / 2, size / 2) == SampleRecord.capped,
        "c = -1: the critical point escaped")
      try require(
        sample(rabbit, 1, 1) != SampleRecord.capped, "c = -1: a far corner did not escape")
      try require(
        (0..<size * size).contains { index in
          rabbit.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * 8, as: UInt32.self) }
            != sample(disc, index % size, index / size)
        }, "Changing c did not change the picture")

      // Rotation: the companion turns about the centre of the panel.  For c = 0
      // the picture is radially symmetric, so a rotated render must still obey
      // the unit-disc rule at every pixel's (rotation-invariant) radius.
      var turned = Viewport(center: .zero, scale: 1)
      turned.angle = Viewport.normalised(37 * .pi / 180)
      _ = try await gpu.julia(into: samples, viewport: turned, c: .zero, iterations: 2000)
      let tilted = try await gpu.readback(samples)
      for y in 0..<size {
        for x in 0..<size {
          let n = sample(tilted, x, y)
          let span = turned.span
          let vx = (Double(x) + 0.5 - Double(size) / 2) * span / Double(size)
          let vy = (Double(size) / 2 - (Double(y) + 0.5)) * span / Double(size)
          let radius = hypot(vx, vy)
          if radius < 0.98 {
            try require(n == SampleRecord.capped, "Rotated c = 0: |z| = \(radius) escaped")
          } else if radius > 1.02 {
            try require(n != SampleRecord.capped, "Rotated c = 0: |z| = \(radius) did not escape")
          }
        }
      }
      // And with an asymmetric c, a quarter turn is the matching permutation of
      // the upright render: (vx, vy) becomes (-vy, vx).  cos and sin are floats,
      // so boundary pixels may differ; the bulk may not.
      // (vx, vy) -> (-vy, vx) means the pixel at (x, y) comes from (y, size-1-x).
      let c = CGPoint(x: -0.8, y: 0.156)
      let upright = Viewport(center: .zero, scale: 1)
      _ = try await gpu.julia(into: samples, viewport: upright, c: c, iterations: 2000)
      let straight = try await gpu.readback(samples)
      var quarter = upright
      quarter.angle = .pi / 2
      _ = try await gpu.julia(into: samples, viewport: quarter, c: c, iterations: 2000)
      let rotated = try await gpu.readback(samples)
      var permuted = 0
      var direct = 0
      for y in 0..<size {
        for x in 0..<size {
          if sample(rotated, x, y) != sample(straight, y, size - 1 - x) { permuted += 1 }
          if sample(rotated, x, y) != sample(straight, x, y) { direct += 1 }
        }
      }
      try require(
        permuted * 100 < size * size,
        "A quarter turn was not the quarter-turn permutation (\(permuted) pixels differ)")
      try require(
        direct * 10 > size * size,
        "A quarter turn did not rotate the picture at all (\(direct) pixels differ)")

      // The renderer caches: nothing changed means no second render.
      let model = ExplorerModel()
      model.resize(CGSize(width: 800, height: 500), displayScale: 2)
      model.showJulia = true
      let first = await model.julia.update(
        c: model.juliaC, viewport: model.juliaViewport, width: 64, height: 64, iterations: 400,
        colouring: model.colouring, gpu: gpu)
      let second = await model.julia.update(
        c: model.juliaC, viewport: model.juliaViewport, width: 64, height: 64, iterations: 400,
        colouring: model.colouring, gpu: gpu)
      try require(first && !second, "The companion re-rendered an unchanged view")
      try require(model.julia.colour != nil && model.julia.error == nil, "The companion failed")

      // Tracking follows the pointer, and stops while the companion is swapped.
      model.trackJulia(at: CGPoint(x: 100, y: 120))
      let tracked = model.juliaC
      try require(
        tracked == model.viewport.complex(at: CGPoint(x: 100, y: 120), in: model.size),
        "The companion did not follow the pointer")
      model.swapJulia()
      model.trackJulia(at: CGPoint(x: 300, y: 200))
      try require(model.juliaC == tracked, "A swapped companion still followed the pointer")
      // Swapped, gestures drive the companion's own view.
      let mandelbrot = model.viewport
      let companion = model.juliaViewport
      model.pan(CGSize(width: 40, height: 0))
      model.zoom(2, at: CGPoint(x: 400, y: 250))
      try require(
        model.viewport == mandelbrot && model.juliaViewport != companion,
        "Gestures moved the wrong view while swapped")
      try require(model.juliaViewport.logScale > companion.logScale, "The companion did not zoom")
      // Rotation follows the swap as pan and zoom do, and so does the compass.
      let behind = model.viewport
      model.rotate(20 * .pi / 180)
      try require(
        model.viewport == behind && abs(model.juliaViewport.angle - 20 * .pi / 180) < 1e-9,
        "Rotating the main view turned the companion behind it instead")
      try require(
        abs(model.mainViewport.angle - model.juliaViewport.angle) < 1e-12,
        "The compass reads an angle that is not the one on screen")
      model.resetRotation()
      var now = ProcessInfo.processInfo.systemUptime
      for _ in 0..<120 {
        now += 1 / 60
        model.advanceMotion(now: now)
      }
      try require(
        model.juliaViewport.angle == 0 && model.rotationTarget == nil,
        "The compass did not return the swapped companion to upright")
      try require(model.viewport == behind, "The compass turned the view behind the companion")
      // It stays shallow: float and double-float only.
      for _ in 0..<60 { model.zoom(4, at: CGPoint(x: 400, y: 250)) }
      try require(model.juliaViewport.logScale < 26, "The companion zoomed past its precision")
      // A swapped companion must not keep the display awake for a spring it
      // cannot apply.
      model.viewport = Viewport(center: CGPoint(x: 40, y: 25), scale: 8)
      try require(
        model.boundsNeeded && !model.isAnimating,
        "A swapped view kept the display awake for a spring it cannot apply")
      model.swapJulia()
      try require(model.isAnimating, "Unswapping did not resume the bounds spring")
      model.stopMotion()
      model.setActive(false)
    }
    /// The panel's own view, which nothing used to drive.  SwiftUI updates a
    /// representable only when its value changes, and the panel's surface
    /// carried nothing but a model reference and a size, so it was never marked
    /// dirty: in hands-on use the panel was never seen to update.  The scene it
    /// draws is now a value, and the model has a redraw route of its own.
    static func checkCompanionPanel(_ gpu: GPUContext) async throws {
      let model = ExplorerModel()
      model.resize(CGSize(width: 800, height: 500), displayScale: 2)
      model.panelSize = CGSize(width: 220, height: 220)
      model.showJulia = true
      var redraws = 0
      model.onJuliaRedrawNeeded = { redraws += 1 }

      // Everything the panel draws from moves its value, so SwiftUI has a
      // reason to update it, and the redraw route asks for a frame besides.
      var scene = model.juliaScene
      func changed(_ what: String, _ change: () -> Void) throws {
        let before = redraws
        change()
        try require(model.juliaScene != scene, "The panel's view ignores \(what)")
        try require(redraws > before, "Changing \(what) did not ask the panel for a frame")
        scene = model.juliaScene
      }
      try changed("c") { model.trackJulia(at: CGPoint(x: 120, y: 140)) }
      try changed("the companion's view") { model.zoomPanel(2) }
      try changed("the palette") { model.colouring = ColourSettings(palette: .fire) }
      try changed("the swap") { model.swapJulia() }
      model.swapJulia()
      scene = model.juliaScene

      // And the panel's own view really renders: drive the coordinator the way
      // the view does and the texture must arrive, and change with c.
      let view = MTKView(frame: .zero, device: gpu.device)
      let coordinator = JuliaCoordinator(model: model)
      view.delegate = coordinator
      coordinator.adopt(model, view: view)
      func drawPanel() async {
        coordinator.draw(in: view)
        // The coordinator renders in a task of its own and presents the result
        // on the frame after; let it run, then draw again.
        for _ in 0..<40 {
          await Task.yield()
          try? await Task.sleep(for: .milliseconds(5))
          if !model.julia.isBusy && model.julia.colour != nil { break }
        }
      }
      model.juliaC = CGPoint(x: -0.8, y: 0.156)
      await drawPanel()
      guard let colour = model.julia.colour else {
        throw GPUFailure("Driving the panel's own view produced no picture")
      }
      let first = try await gpu.readback(colour)
      try require(model.julia.error == nil, "The panel's own view failed to render")
      model.juliaC = CGPoint(x: 0.285, y: 0.01)
      await drawPanel()
      let second = try await gpu.readback(model.julia.colour!)
      try require(first != second, "Moving c did not change what the panel draws")

      // Pinning: the crosshair follows until it is pinned, a drag moves it and
      // pins it, and a pinned point survives panning and zooming.
      model.juliaPinned = false
      model.trackJulia(at: CGPoint(x: 200, y: 200))
      let followed = model.juliaC
      model.toggleJuliaPin()
      try require(model.juliaPinned, "Clicking the crosshair did not pin it")
      model.trackJulia(at: CGPoint(x: 500, y: 300))
      try require(model.juliaC == followed, "A pinned crosshair still followed the pointer")
      model.dragJulia(to: CGPoint(x: 500, y: 300))
      try require(
        model.juliaC == model.viewport.complex(at: CGPoint(x: 500, y: 300), in: model.size)
          && model.juliaPinned,
        "Dragging the crosshair did not move it, or released the pin")
      let pinned = model.juliaC
      guard let before = model.juliaMarker else { throw GPUFailure("The crosshair is not drawn") }
      model.pan(CGSize(width: -60, height: 25))
      model.zoom(1.5, at: model.centreOfView)
      try require(model.juliaC == pinned, "Panning and zooming moved the pinned point")
      guard let after = model.juliaMarker else { throw GPUFailure("The crosshair went missing") }
      try require(
        after != before
          && abs(after.x - model.viewport.screen(for: pinned, in: model.size).x) < 1e-6,
        "The crosshair did not stay on its point through a pan and a zoom")
      try require(
        model.isOnJuliaMarker(after)
          && !model.isOnJuliaMarker(CGPoint(x: after.x + 60, y: after.y)),
        "The crosshair is grabbed from the wrong place")
      // The setting switches following off without unpinning.
      model.juliaPinned = false
      model.juliaFollows = false
      let still = model.juliaC
      model.trackJulia(at: CGPoint(x: 90, y: 90))
      try require(model.juliaC == still, "The companion followed with following switched off")
      try require(
        UserDefaults.standard.bool(forKey: ExplorerModel.followsKey) == false,
        "The following setting was not remembered")
      model.juliaFollows = true

      // The panel's own gestures: no swap needed to move the companion, and
      // while swapped they drive the Mandelbrot the panel is showing.
      let mandelbrot = model.viewport
      let companion = model.juliaViewport
      model.panPanel(CGSize(width: 30, height: -10))
      model.zoomPanel(4, at: CGPoint(x: 110, y: 110))
      model.rotatePanel(15 * .pi / 180)
      try require(
        model.viewport == mandelbrot, "A gesture in the panel moved the main view")
      try require(
        model.juliaViewport != companion
          && model.juliaViewport.logScale > companion.logScale
          && abs(model.juliaViewport.angle - 15 * .pi / 180) < 1e-9,
        "The panel's own gestures did not pan, zoom and rotate the companion")
      for _ in 0..<60 { model.zoomPanel(4) }
      try require(model.juliaViewport.logScale < 26, "The panel zoomed past its precision")
      model.resetPanel()
      try require(
        model.juliaViewport == Viewport(center: .zero, scale: 1),
        "Resetting the panel did not return the companion to its whole view")
      model.swapJulia()
      let swappedCompanion = model.juliaViewport
      model.panPanel(CGSize(width: 20, height: 0))
      try require(
        model.viewport != mandelbrot && model.juliaViewport == swappedCompanion,
        "While swapped the panel's gestures moved the companion, not the Mandelbrot")
      model.swapJulia()
      model.setActive(false)
    }
  }
#endif
