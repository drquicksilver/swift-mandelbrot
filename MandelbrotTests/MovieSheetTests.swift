import AVKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import Mandelbrot

#if os(macOS)
  typealias PlatformView = NSView
#else
  typealias PlatformView = UIView
#endif

/// What the Mac sheet does when its buttons are pressed, minus the pressing:
/// the thumbnails at the ends of the journey, the zoom it labels them with, and
/// a whole render through the renderer the Render button starts.
@MainActor struct MovieSheetTests {
  @Test func thumbnailRendersTheWholeSet() async throws {
    try #require(GPUContext.shared != nil, "No GPU in this environment")
    let thumbnail = LocationThumbnail()
    await thumbnail.render(Location.gallery[0], width: 232, height: 140)
    let image = try #require(thumbnail.image)
    #expect(image.width == 232)
    #expect(image.height == 140)
    thumbnail.release()
  }

  #if os(macOS)
    @Test func zoomReadsPlainlyUntilTheDigitsStopMeaningAnything() throws {
      #expect(MovieSheetMac.zoom(Location.gallery[0]) == "1×")
      #expect(MovieSheetMac.zoom(Location.gallery[1]) == "4,000×")
      // A 1e100 descent: an exponent, not a hundred digits.
      let deep = MovieSheetMac.zoom(Location.gallery.last!)
      #expect(deep.hasSuffix("e100×"))
    }
  #endif

  #if os(macOS)
    /// The sandbox has to let a movie reach the folder the sheet names, which
    /// is `~/Movies` through the container's symlink.  Without the movies-folder
    /// entitlement this is where a render died, with "you don't have
    /// permission" after every frame had been rendered.
    @Test func theMovieFolderIsWritable() throws {
      let url = MovieLibrary.shared.destination(named: "MovieSheetTests-\(UUID().uuidString).probe")
      defer { try? FileManager.default.removeItem(at: url) }
      try Data("probe".utf8).write(to: url)
      #expect(FileManager.default.fileExists(atPath: url.path))
    }
  #endif

  #if os(macOS)
    /// `VideoPlayer` is a SwiftUI wrapper around AVKit's `AVPlayerView`, but
    /// importing AVKit only linked `_AVKit_SwiftUI`, not AVKit itself.  Showing
    /// the finished movie then crashed the app in the Swift runtime: "failed to
    /// demangle superclass of VideoPlayerView from mangled name
    /// 'So12AVPlayerViewC'" -- the superclass is in a framework that was never
    /// loaded.  This fails long before a person would see that.
    @Test func avKitIsLinkedForTheFinishedMoviesPlayer() {
      #expect(NSClassFromString("AVPlayerView") != nil)
    }
  #endif

  /// Builds the view SwiftUI builds when a render finishes.  This is the step
  /// that aborted the process on macOS: realising `VideoPlayer` instantiates a
  /// class whose superclass lives in AVKit, which nothing had linked.  A crash
  /// here fails the suite instead of the app.
  ///
  /// The view has to be in a window, or SwiftUI never makes the representable
  /// and the crash never happens -- which is exactly how this got shipped.
  ///
  /// It runs on both platforms, though only macOS was ever affected: with the
  /// framework unlinked this aborts on the Mac and passes on the iOS simulator,
  /// which finds AVKit some other way.
  @Test func theFinishedMoviesPlayerCanBeRealised() async throws {
    let player = AVPlayer()
    let frame = CGRect(x: 0, y: 0, width: 320, height: 180)
    #if os(macOS)
      let window = NSWindow(
        contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
      window.contentView = NSHostingView(rootView: VideoPlayer(player: player))
      window.orderFront(nil)
      window.contentView?.layoutSubtreeIfNeeded()
      let root = try #require(window.contentView)
    #else
      let window = UIWindow(frame: frame)
      window.rootViewController = UIHostingController(
        rootView: VideoPlayer(player: player))
      window.makeKeyAndVisible()
      window.layoutIfNeeded()
      let root = try #require(window.rootViewController?.view)
    #endif
    // A moment for SwiftUI to build what the window asked for.
    try await Task.sleep(for: .milliseconds(500))
    #expect(Self.holdsAPlayerView(root), "No AVKit player view was ever made")
  }

  /// AVKit's own view, somewhere under the one SwiftUI made.
  private static func holdsAPlayerView(_ view: PlatformView) -> Bool {
    if String(describing: type(of: view)).contains("AVPlayer") { return true }
    return view.subviews.contains { holdsAPlayerView($0) }
  }

  /// The whole path the Render button takes: a zoom path, a render, a file.
  /// Small on purpose -- it is the plumbing under test, not the picture.
  @Test func aShortRenderWritesAPlayableMovie() async throws {
    try #require(GPUContext.shared != nil, "No GPU in this environment")
    let path = try ZoomPath(
      start: Location.gallery[0],
      end: Location(name: "", real: "-0.743643887037151", imag: "0.13182590420533", scale: "100"))
    var settings = MovieSettings()
    settings.width = 320
    settings.height = 180
    settings.duration = 2
    settings.framesPerSecond = 24
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("MovieSheetTests-\(UUID().uuidString).mov")
    defer { try? FileManager.default.removeItem(at: url) }
    let movies = MovieRenderer()
    _ = try await movies.render(
      path: path, settings: settings, colouring: ColourSettings(), to: url)
    #expect(movies.output == url)
    let size = try #require(
      FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
    #expect(size > 0)
    #expect(movies.counts.frames == settings.frameCount)
    #expect(movies.counts.keyframes == path.keyframeLevels.count)
  }
}
