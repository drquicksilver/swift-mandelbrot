import Combine
import CoreGraphics
import Foundation
import SwiftUI

/// Renders a small still of one location, for the ends of a zoom movie.
///
/// It is the movie renderer's keyframe in miniature: a store of its own, one
/// update, and a composited snapshot.  The store is kept between renders so
/// changing the starting place redraws from whatever is already cached, and its
/// budget is small because two of these are alive beside the viewer's own cache.
@MainActor final class LocationThumbnail: ObservableObject {
  @Published private(set) var image: CGImage?
  @Published private(set) var isRendering = false
  private var store: TileStore?
  /// What the last render drew, so repeated body evaluations do not redraw it.
  private var drawn: String?

  static let budgetBytes = 24 * 1024 * 1024

  /// A key that changes only when the picture would: the identity of a location
  /// is a fresh UUID every time the model makes one, which is not that.
  static func key(_ location: Location) -> String {
    "\(location.real)|\(location.imag)|\(location.scale)|\(location.rotationDegrees)"
      + "|\(location.palette.rawValue)|\(location.density)|\(location.offset)"
  }

  func render(_ location: Location, width: Int, height: Int) async {
    let key = Self.key(location)
    guard key != drawn else { return }
    isRendering = true
    defer { isRendering = false }
    do {
      let view = try location.viewport()
      let size = CGSize(width: width, height: height)
      let store = store ?? TileStore(budgetBytes: Self.budgetBytes)
      self.store = store
      let colouring = ColourSettings(
        palette: location.palette, density: Float(location.density),
        offset: Float(location.offset))
      let limit =
        location.iterations ?? IterationPolicy.estimate(logScale: view.logScale)
      store.update(
        viewport: view, size: size, pixelWidth: size.width, iterations: limit,
        override: nil, colouring: colouring)
      try await store.waitUntilReady()
      let texture = try await TileCompositor.snapshot(
        store: store, viewport: view, width: width, height: height,
        now: ProcessInfo.processInfo.systemUptime + TilePresentation.fadeDuration)
      guard let gpu = GPUContext.shared else { return }
      image = try await gpu.image(texture)
      drawn = key
    } catch {
      // A thumbnail is decoration: a failure leaves the placeholder in place.
      image = nil
    }
  }

  /// Gives back the store's memory once the sheet that wanted the picture goes.
  func release() {
    store?.cancel()
    store = nil
  }
}
