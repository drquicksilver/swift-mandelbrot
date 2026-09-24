// The Julia companion's renderer, which Viewer/JuliaCanvas.swift draws from.
// Its kernel, `renderJulia`, sits in Shaders/GPUCompute.metal beside the
// tiles' own, and shares their sample format and palettes.

import CoreGraphics
import Foundation
import Metal

/// The Julia companion's renderer: one small float (or double-float) render per
/// change, coloured by the same palette kernel as the tiles.  It is deliberately
/// not tiled: the panel is small, always redrawn whole, and never goes deep.
@MainActor final class JuliaRenderer {
  private struct Request: Equatable {
    var c: CGPoint
    var viewport: Viewport
    var width: Int
    var height: Int
    var iterations: Int
    var colouring: ColourSettings
  }
  /// The companion's own limit, which governs its quality when the main view is
  /// deep: the panel is small and redrawn whole in one unbatched dispatch, so it
  /// does not follow a deep view's tens of thousands of iterations.
  static let maximumIterations = 4000
  private var samples: MTLTexture?
  private var last: Request?
  private var rendering = false
  private(set) var colour: MTLTexture?
  private(set) var error: String?
  var isBusy: Bool { rendering }
  /// Renders when anything has changed, and reports whether the texture is new.
  @discardableResult func update(
    c: CGPoint, viewport: Viewport, width: Int, height: Int, iterations: Int,
    colouring: ColourSettings, gpu: GPUContext
  ) async -> Bool {
    let request = Request(
      c: c, viewport: viewport, width: max(16, width), height: max(16, height),
      iterations: max(32, min(iterations, Self.maximumIterations)), colouring: colouring)
    guard !rendering, request != last else { return false }
    rendering = true
    defer { rendering = false }
    do {
      if samples?.width != request.width || samples?.height != request.height {
        samples = try gpu.texture(width: request.width, height: request.height, format: .rg32Uint)
        colour = try gpu.texture(width: request.width, height: request.height, format: .rgba8Unorm)
      }
      guard let samples, let colour else { return false }
      _ = try await gpu.julia(
        into: samples, viewport: request.viewport, c: request.c, iterations: request.iterations)
      _ = try await gpu.colour(
        samples, into: colour, settings: request.colouring, iterations: request.iterations)
      last = request
      error = nil
      return true
    } catch {
      self.error = String(describing: error)
      return false
    }
  }
}

/// Everything the companion panel draws from, as one value.  SwiftUI updates a
/// representable only when its value changes, so the panel's view has to carry
/// this rather than just a reference to the model.
struct JuliaScene: Equatable {
  var c: CGPoint
  var viewport: Viewport
  var iterations: Int
  var colouring: ColourSettings
  var swapped: Bool
}
