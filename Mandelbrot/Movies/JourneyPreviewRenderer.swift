// The movie sheet's quick look at a journey: a small, low-frame-rate movie made
// by the real movie renderer, so the preview follows exactly the camera path
// the finished movie will.

import AVFoundation
import Combine
import Foundation

/// A lightweight, disposable movie for the journey sheet. The preview uses the
/// production journey renderer, so the player and exported movie share the
/// same camera path; it merely trades resolution and frame rate for speed.
@MainActor final class JourneyPreviewRenderer: ObservableObject {
  static let width = 480
  static let height = 270
  static let framesPerSecond = 12
  static let tileBudgetBytes = 64 * 1024 * 1024

  @Published private(set) var player: AVPlayer?
  @Published private(set) var isRendering = false
  @Published private(set) var error: String?
  /// How far the preview has got, from its renderer: fast near the top of
  /// the set, slow enough to want a bar on a deep journey.
  @Published private(set) var progress = 0.0

  private var task: Task<Void, Never>?
  private var progressObservation: AnyCancellable?
  private var request = 0
  private var url: URL?

  func start(journey: Journey, settings: MovieSettings, colouring: ColourSettings) {
    cancel()
    request &+= 1
    let request = request
    isRendering = true
    error = nil
    progress = 0
    let renderer = MovieRenderer()
    renderer.showsStills = false
    progressObservation = renderer.$progress.sink { [weak self] value in
      MainActor.assumeIsolated { self?.progress = value }
    }
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("Mandelbrot-journey-preview-\(UUID().uuidString).mov")
    var proxy = settings
    proxy.width = Self.width
    proxy.height = Self.height
    proxy.framesPerSecond = Self.framesPerSecond
    task = Task { [weak self] in
      guard let self else { return }
      do {
        let store = TileStore(budgetBytes: Self.tileBudgetBytes)
        defer { store.cancel() }
        _ = try await renderer.render(
          journey: journey, settings: proxy, colouring: colouring, to: destination, store: store)
        guard !Task.isCancelled, request == self.request else {
          try? FileManager.default.removeItem(at: destination)
          return
        }
        self.url.map { try? FileManager.default.removeItem(at: $0) }
        self.url = destination
        self.player = AVPlayer(url: destination)
        self.isRendering = false
      } catch is CancellationError {
        try? FileManager.default.removeItem(at: destination)
      } catch {
        try? FileManager.default.removeItem(at: destination)
        guard request == self.request else { return }
        self.error = MovieRenderer.explain(
          error, fallback: String(localized: "The preview couldn’t be made."))
        self.isRendering = false
      }
    }
  }

  func cancel() {
    request &+= 1
    task?.cancel()
    task = nil
    progressObservation = nil
    progress = 0
    player?.pause()
    player = nil
    isRendering = false
    error = nil
    if let url {
      try? FileManager.default.removeItem(at: url)
      self.url = nil
    }
  }
}
