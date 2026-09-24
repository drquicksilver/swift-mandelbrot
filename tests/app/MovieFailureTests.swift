// What a person is told when a movie fails: sentences written for people pass
// through, anything else is replaced, and writer failures name their cause.

import AVFoundation
import Foundation
import Testing

@testable import Mandelbrot

/// What a person is told when a movie fails.  These used to be chosen by
/// searching the thrown text, which named the wrong cause (review finding 3).
@MainActor struct MovieFailureTests {
  let writeFailed = MovieFailure.writerFailed(nil).message

  @Test func sentencesWrittenForPeoplePassThrough() {
    let copy = UserError("Zoom in further than the starting place.")
    #expect(MovieRenderer.message(for: copy) == copy.message)
  }

  @Test func textWrittenForTheCodeIsNeverShown() {
    let technical = PrecisionError("Invalid decimal coordinate")
    let shown = MovieRenderer.message(for: technical, fallback: "This journey can’t be planned.")
    #expect(shown == "This journey can’t be planned.")
    #expect(!MovieRenderer.message(for: technical).contains("decimal"))
  }

  @Test func writerFailuresAreNamedByTheirCause() {
    // AVFoundation reports file trouble as an underlying error, so the cause
    // is found through the chain, not at the top.
    let denied = NSError(
      domain: AVFoundationErrorDomain, code: AVError.Code.unknown.rawValue,
      userInfo: [
        NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
      ])
    let full = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
    let permission = MovieFailure.writerFailed(denied).message
    let space = MovieFailure.writerFailed(full).message
    #expect(permission.contains("folder"))
    #expect(space.contains("room on the disk"))
    #expect(Set([permission, space, writeFailed]).count == 3)
    // Neither memory nor drawing is a disk problem.
    #expect(!MovieFailure.outOfMemory.message.contains("disk"))
    #expect(!MovieFailure.cannotDraw("no texture").message.contains("disk"))
  }

  /// A real render into a folder that cannot be written: the permission
  /// failure has to survive the trip through AVAssetWriter.
  @Test func aReadOnlyFolderIsReportedAsAFolderProblem() async throws {
    try #require(GPUContext.shared != nil, "No GPU in this environment")
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("MovieFailureTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: folder.path)
      try? FileManager.default.removeItem(at: folder)
    }
    let path = try ZoomPath(
      start: Location.gallery[0],
      end: Location(real: "-0.743643887037151", imag: "0.13182590420533", scale: "100"))
    var settings = MovieSettings()
    settings.width = 320
    settings.height = 180
    settings.duration = 2
    do {
      _ = try await MovieRenderer().render(
        path: path, settings: settings, colouring: ColourSettings(),
        to: folder.appendingPathComponent("movie.mov"))
      Issue.record("A render into a read-only folder succeeded")
    } catch {
      #expect(error is MovieFailure, "Untyped failure: \(error)")
      #expect(MovieRenderer.message(for: error).contains("folder"), "\(error)")
    }
  }
}
