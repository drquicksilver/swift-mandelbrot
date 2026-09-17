#if os(macOS)
  import CoreGraphics
  import Foundation
  import Metal

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
      // c = -1: zero is periodic, and a point well outside the set escapes fast.
      _ = try await gpu.julia(
        into: samples, viewport: Viewport(center: .zero, scale: 1), c: CGPoint(x: -1, y: 0),
        iterations: 2000)
      let rabbit = try await gpu.readback(samples)
      func sample(_ data: Data, _ x: Int, _ y: Int) -> UInt32 {
        data.withUnsafeBytes {
          $0.loadUnaligned(fromByteOffset: (y * size + x) * 8, as: UInt32.self)
        }
      }
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
  }
#endif
