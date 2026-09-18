#if os(macOS)
  import AVFoundation
  import CoreGraphics
  import Foundation
  import Metal

  extension TileDiagnostics {
    /// Renders a short movie and reads it back: the frames are there, at the
    /// right times, and the last one matches a direct render of the destination.
    static func checkZoomMovie(_ gpu: GPUContext) async throws -> [String: Double] {
      let width = 320
      let height = 180
      let end = Location(
        name: "Seahorse", real: "-0.743643887037151", imag: "0.13182590420533", scale: "4e3",
        palette: .ink)
      let path = try ZoomPath(start: Location(real: "-0.5", imag: "0", scale: "1"), end: end)
      var settings = MovieSettings(duration: 1, width: width, height: height, framesPerSecond: 15)
      settings.paletteCycles = 0
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "diagnostic-zoom.mov")
      let renderer = MovieRenderer()
      let began = ProcessInfo.processInfo.systemUptime
      _ = try await renderer.render(
        path: path, settings: settings, colouring: end.colouring, to: url)
      let seconds = ProcessInfo.processInfo.systemUptime - began
      defer { try? FileManager.default.removeItem(at: url) }
      try require(renderer.progress == 1, "The movie reported incomplete progress")

      let asset = AVURLAsset(url: url)
      let tracks = try await asset.loadTracks(withMediaType: .video)
      guard let track = tracks.first else { throw GPUFailure("The movie has no video track") }
      let naturalSize = try await track.load(.naturalSize)
      try require(
        Int(naturalSize.width) == width && Int(naturalSize.height) == height,
        "The movie is \(naturalSize), not \(width)x\(height)")
      let reader = try AVAssetReader(asset: asset)
      let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
      reader.add(output)
      reader.startReading()
      var frames = 0
      var times: [Double] = []
      var last: [UInt8] = []
      var first: [UInt8] = []
      var middle: [UInt8] = []
      let middleIndex = settings.frameCount / 2
      while let sample = output.copyNextSampleBuffer() {
        frames += 1
        times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        if let buffer = CMSampleBufferGetImageBuffer(sample) {
          CVPixelBufferLockBaseAddress(buffer, .readOnly)
          let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
          if let base = CVPixelBufferGetBaseAddress(buffer) {
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0..<height {
              memcpy(
                &pixels[y * width * 4], base.advanced(by: y * bytesPerRow), width * 4)
            }
            if frames == 1 { first = pixels }
            if frames == middleIndex + 1 { middle = pixels }
            last = pixels
          }
          CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
      }
      try require(
        frames == settings.frameCount,
        "The movie has \(frames) frames, not \(settings.frameCount)")
      for (index, time) in times.enumerated() {
        try require(
          abs(time - Double(index) / 15) < 1e-6, "Frame \(index) is timed at \(time)")
      }
      try require(Set(last).count > 32 && Set(first).count > 32, "A movie frame is flat")

      // The last frame is the destination, and the first is the whole set.
      func direct(_ level: Double, cycles: Double = 0) async throws -> [UInt8] {
        let store = TileStore()
        let view = path.viewport(at: level)
        var colouring = end.colouring
        colouring.offset = Float(path.paletteOffset(at: level, cycles: cycles))
        store.update(
          viewport: view, size: CGSize(width: width, height: height), pixelWidth: Double(width),
          iterations: path.iterations(at: level), override: nil, colouring: colouring)
        try await store.waitUntilReady()
        let texture = try await TileCompositor.snapshot(
          store: store, viewport: view, width: width, height: height,
          now: ProcessInfo.processInfo.systemUptime + 1)
        let data = try await gpu.readback(texture)
        store.cancel()
        return [UInt8](data)
      }
      func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 255 }
        var total = 0.0
        for index in stride(from: 0, to: a.count, by: 4) {
          for channel in 0..<3 {
            total += abs(Double(a[index + channel]) - Double(b[index + channel]))
          }
        }
        return total / Double(a.count / 4 * 3)
      }
      let endFrame = try await direct(path.endLog)
      let startFrame = try await direct(path.startLog)
      let endError = difference(last, endFrame)
      let startError = difference(first, startFrame)
      try require(
        endError < 16, "The last movie frame differs from the destination by \(endError)")
      try require(
        startError < 16, "The first movie frame differs from the start by \(startError)")
      try require(
        difference(first, endFrame) > 24, "The movie's ends are indistinguishable")
      // A frame between keyframes blends both through the affine map: check one
      // against a direct render at the same level, where nothing is blended.
      let middleLevel = path.level(at: Double(middleIndex) / Double(settings.frameCount - 1))
      let middleError = difference(middle, try await direct(middleLevel))
      try require(
        middleError < 20,
        "An interpolated frame differs from a direct render by \(middleError)")

      // Every keyframe's depth is recorded, and is the automatic estimate for its
      // level: what a movie's iteration budget actually is, for Performance.md.
      let limits = renderer.keyframeLimits
      try require(
        limits.count == path.keyframeLevels.count,
        "\(limits.count) keyframe limits recorded for \(path.keyframeLevels.count) keyframes")
      try require(
        limits.allSatisfy { $0.limit == IterationPolicy.estimate(logScale: $0.level) },
        "A keyframe was rendered at a depth other than its estimate")

      // Palette cycling changes the colouring along the descent.
      var cycling = settings
      cycling.paletteCycles = 4
      let cyclingURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "diagnostic-cycled.mov")
      _ = try await MovieRenderer().render(
        path: path, settings: cycling, colouring: end.colouring, to: cyclingURL)
      defer { try? FileManager.default.removeItem(at: cyclingURL) }
      try require(
        FileManager.default.fileExists(atPath: cyclingURL.path),
        "The cycled movie was not written")
      print(
        "Zoom movie: \(frames) frames from \(path.keyframeLevels.count) keyframes in "
          + "\(String(format: "%.2f", seconds)) s; end error \(String(format: "%.1f", endError))/255, "
          + "middle error \(String(format: "%.1f", middleError))/255"
      )
      return [
        "movieFrames": Double(frames), "movieKeyframes": Double(path.keyframeLevels.count),
        "movieSeconds": seconds, "movieEndError": endError, "movieMiddleError": middleError,
      ]
    }

    /// A movie on a phone's memory: the store used to ask for a flat 512 MiB,
    /// 3.4x the whole iOS viewer budget, beside the viewer's own live cache.
    static func checkMovieOnASmallBudget(_ gpu: GPUContext) async throws {
      let end = Location(
        name: "Seahorse", real: "-0.743643887037151", imag: "0.13182590420533", scale: "4e3",
        palette: .ink)
      let path = try ZoomPath(start: Location(real: "-0.5", imag: "0", scale: "1"), end: end)
      let settings = MovieSettings(
        duration: 1, width: 320, height: 180, framesPerSecond: 15)
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "diagnostic-small.mov")
      let budget = 24 * 1024 * 1024
      let store = TileStore(budgetBytes: budget)
      _ = try await MovieRenderer().render(
        path: path, settings: settings, colouring: end.colouring, to: url, store: store)
      defer { try? FileManager.default.removeItem(at: url) }
      try require(
        FileManager.default.fileExists(atPath: url.path),
        "A movie on a small budget was not written")
      try require(
        store.residentBytes <= store.tileResidentLimit,
        "A movie left \(store.residentBytes) bytes against a \(store.tileResidentLimit) limit")
      // A render that is given no store must not ask for more than the viewer
      // itself would, and no offered resolution's keyframe pair may crowd it.
      try require(
        MovieRenderer.defaultBudgetBytes <= TileStore().budgetBytes,
        "A movie's own store asks for more than the whole viewer budget")
      for option in MovieSettings.resolutions {
        let pair = option.width * option.height * 4 * 2
        try require(
          pair * 4 <= MovieRenderer.defaultBudgetBytes,
          "\(option.name) keyframes are \(pair / 1024 / 1024) MiB against a "
            + "\(MovieRenderer.defaultBudgetBytes / 1024 / 1024) MiB budget")
      }
      store.cancel()
      print(
        "Movie on a \(budget / 1024 / 1024) MiB store: "
          + "\(store.residentBytes / 1024 / 1024) MiB resident of "
          + "\(store.tileResidentLimit / 1024 / 1024) MiB")
    }

  }
#endif
