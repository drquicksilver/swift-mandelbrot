// Pictures of places without a window: the Mac's Places library and the movie
// sheet's two ends are drawn by these, each through a small tile store of its
// own and the same compositor as the viewer.

import Combine
import CoreGraphics
import Foundation
import SwiftUI

/// Renders a small still of one location.
///
/// It is the movie renderer's keyframe in miniature: a store of its own, one
/// update, and a composited snapshot.  The store is kept between renders so
/// changing the place redraws from whatever is already cached, and its budget
/// is small because several of these are alive beside the viewer's own cache.
@MainActor final class LocationThumbnail: ObservableObject {
  @Published private(set) var image: CGImage?
  @Published private(set) var isRendering = false
  private var store: TileStore?
  /// What the last render drew, so repeated body evaluations do not redraw it.
  private var drawn: String?
  /// SwiftUI cancels the previous `.task(id:)` while a slider is being
  /// scrubbed.  A thumbnail render has several suspension points, so an older
  /// cancelled request must never blank the image or finish after the newer
  /// request and claim that rendering has stopped.
  private var generation = 0

  static let budgetBytes = 24 * 1024 * 1024

  /// A key that changes only when the picture would: the identity of a location
  /// is a fresh UUID every time the model makes one, which is not that.
  static func key(_ location: Location) -> String {
    "\(location.real)|\(location.imag)|\(location.scale)|\(location.rotationDegrees)"
      + "|\(location.palette.rawValue)|\(location.density)|\(location.offset)"
      + "|\(location.automaticColour.map(String.init) ?? "historic")"
  }

  func render(_ location: Location, width: Int, height: Int) async {
    let key = Self.key(location)
    guard key != drawn else { return }
    generation &+= 1
    let request = generation
    isRendering = true
    defer {
      if request == generation { isRendering = false }
    }
    do {
      let view = try location.viewport()
      let size = CGSize(width: width, height: height)
      let store = store ?? TileStore(budgetBytes: Self.budgetBytes)
      self.store = store
      let colouring = location.colouring
      let limit =
        location.iterations ?? IterationPolicy.estimate(logScale: view.logScale)
      store.update(
        viewport: view, size: size, pixelWidth: size.width, iterations: limit,
        override: nil, colouring: colouring)
      try await store.waitUntilReady()
      try Task.checkCancellation()
      guard request == generation else { return }
      let texture = try await TileCompositor.snapshot(
        store: store, viewport: view, width: width, height: height,
        now: ProcessInfo.processInfo.systemUptime + TilePresentation.fadeDuration)
      guard let gpu = GPUContext.shared else { return }
      let rendered = try await gpu.image(texture)
      try Task.checkCancellation()
      guard request == generation else { return }
      image = rendered
      drawn = key
    } catch is CancellationError {
      // The next slider position owns the thumbnail now.  Keep the last
      // successful image visible while it is prepared.
    } catch {
      // A thumbnail is decoration.  Preserve the last good image rather than
      // turning the preview black if a transient tile/GPU request fails.
    }
  }

  /// Gives back the store's memory once the sheet that wanted the picture goes.
  func release() {
    generation &+= 1
    store?.cancel()
    store = nil
  }
}

/// Thumbnails for a whole library of places, kept for the life of the app.
///
/// One `LocationThumbnail` per card would be a tile store per card, so the
/// places queue for one renderer instead and wait their turn.  The famous
/// places never change, so a second visit to Places finds them drawn.
@MainActor final class PlaceThumbnails: ObservableObject {
  static let shared = PlaceThumbnails()
  /// Pixels, twice the points a card shows them at.
  static let width = 480
  static let height = 270
  @Published private(set) var images: [String: CGImage] = [:]
  private var order: [String] = []
  private var queue: [Location] = []
  private var worker: Task<Void, Never>?
  private let renderer = LocationThumbnail()
  private let capacity = 64

  func image(for place: Location) -> CGImage? { images[LocationThumbnail.key(place)] }

  func request(_ place: Location) {
    let key = LocationThumbnail.key(place)
    guard images[key] == nil, !queue.contains(where: { LocationThumbnail.key($0) == key })
    else { return }
    queue.append(place)
    guard worker == nil else { return }
    worker = Task { await drain() }
  }

  #if DEBUG
    /// Hands over a picture drawn elsewhere, as a preview does: its snapshot
    /// is taken before the GPU could draw one.
    func seed(_ image: CGImage, for place: Location) {
      remember(image, for: LocationThumbnail.key(place))
    }
  #endif

  /// Stops drawing what nobody is waiting for, and gives back the store.
  func cancelPending() {
    queue.removeAll()
    worker?.cancel()
    worker = nil
    renderer.release()
  }

  private func drain() async {
    while !queue.isEmpty, !Task.isCancelled {
      let place = queue.removeFirst()
      let before = renderer.image
      await renderer.render(place, width: Self.width, height: Self.height)
      // A failed render leaves the previous picture behind; that is not this
      // place's.
      guard let image = renderer.image, image !== before else { continue }
      remember(image, for: LocationThumbnail.key(place))
    }
    if !Task.isCancelled {
      renderer.release()
      worker = nil
    }
  }

  private func remember(_ image: CGImage, for key: String) {
    if images[key] == nil { order.append(key) }
    images[key] = image
    while order.count > capacity { images[order.removeFirst()] = nil }
  }
}
