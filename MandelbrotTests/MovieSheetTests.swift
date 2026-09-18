import CoreGraphics
import Foundation
import Testing

@testable import Mandelbrot

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
