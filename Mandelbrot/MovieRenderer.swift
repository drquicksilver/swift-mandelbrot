import AVFoundation
import Combine
import CoreGraphics
import CoreVideo
import Foundation
import Metal

struct MovieSettings: Equatable, Sendable {
  var duration = 12.0
  var width = 1920
  var height = 1080
  var framesPerSecond = 30
  /// Palette cycles across the whole descent; zero keeps one mapping.
  var paletteCycles = 0.0
  var eased = true
  /// Snapshot locations can opt into a deterministic automatic-colour
  /// schedule. Old URLs leave this false and retain their historic 64 mapping.
  var automaticColour = false
  var depthAdaptiveColour = false
  var densityAdjustment: Float = 1
  var offsetAdjustment: Float = 0
  var frameCount: Int { max(2, Int((duration * Double(framesPerSecond)).rounded())) }
  /// A phone renders a movie beside the viewer's own cache, on a third of the
  /// memory a Mac has, and a 4K keyframe pair alone is 66 MB, so it stops at
  /// 1080p.
  static let resolutions: [(name: String, width: Int, height: Int)] = {
    let all = [("720p", 1280, 720), ("1080p", 1920, 1080), ("4K", 3840, 2160)]
    #if os(iOS)
      return all.filter { $0.1 <= 1920 }
    #else
      return all
    #endif
  }()
}

/// Where a render has reached, on both of its counters.
struct MovieCounts: Equatable, Sendable {
  var frame = 0
  var frames = 0
  var keyframe = 0
  var keyframes = 0
  /// True while a keyframe is being rendered, which is what the sheet leads
  /// with: the frame it is working towards is waiting on it.
  var onKeyframe = false
}

/// Renders a zoom movie: one keyframe per zoom level straight from the tile
/// cache, then an exponential zoom composed by interpolating between the two
/// keyframes that bracket each frame.  Only two keyframes are ever resident.
@MainActor final class MovieRenderer: ObservableObject {
  @Published private(set) var progress = 0.0
  @Published private(set) var isRendering = false
  @Published private(set) var stage = ""
  /// Both counters a render moves through, so a sheet can show the one it is on
  /// and the one it is between.  Keyframes are where the time goes -- one full
  /// render per zoom level -- and frames are the cheap resamples between them.
  @Published private(set) var counts = MovieCounts()
  @Published var error: String?
  @Published var output: URL?
  private var task: Task<Void, Never>?
  /// The store a render makes for itself, when it is not given one.  A phone
  /// renders beside the viewer's own live cache on a third of a Mac's memory, so
  /// this stays below the viewer's own budget rather than being a flat 512 MiB --
  /// which on iOS was 3.4x the whole viewer budget.  A keyframe is rendered once
  /// and read straight back, so a movie keeps far less resident than exploring.
  static let defaultBudgetBytes: Int = {
    #if os(iOS)
      // Two thirds of the viewer's 150 MiB, since both stores are alive at once.
      return 96 * 1024 * 1024
    #else
      // The viewer's own default on this platform.
      return 500 * 1024 * 1024
    #endif
  }()
  /// The limit each keyframe was rendered at, in order, for the diagnostics.
  private(set) var keyframeLimits: [(level: Double, limit: Int)] = []
  private struct Uniforms {
    var originA = SIMD2<Float>(0, 0), duA = SIMD2<Float>(1, 0), dvA = SIMD2<Float>(0, 1)
    var originB = SIMD2<Float>(0, 0), duB = SIMD2<Float>(1, 0), dvB = SIMD2<Float>(0, 1)
    var blend: Float = 0
    var padding0: Float = 0, padding1: Float = 0, padding2: Float = 0
  }
  /// The affine map from a frame's normalised coordinates into a keyframe's
  /// texture, built from the two viewports so rotation and drift both follow.
  static func mapping(frame: Viewport, keyframe: Viewport, size: CGSize)
    -> (origin: SIMD2<Float>, du: SIMD2<Float>, dv: SIMD2<Float>)
  {
    func uv(_ point: CGPoint) -> SIMD2<Float> {
      let plane = frame.preciseComplex(at: point, in: size)
      let screen = keyframe.screen(for: plane, in: size)
      return SIMD2(Float(screen.x / size.width), Float(screen.y / size.height))
    }
    let origin = uv(.zero)
    return (
      origin, uv(CGPoint(x: size.width, y: 0)) - origin, uv(CGPoint(x: 0, y: size.height)) - origin
    )
  }
  func cancel() {
    task?.cancel()
    task = nil
    isRendering = false
    stage = ""
  }
  func render(
    path: ZoomPath, settings: MovieSettings, colouring: ColourSettings, to url: URL,
    store: TileStore? = nil, colourSchedule: MovieColourSchedule? = nil
  ) async throws -> URL {
    guard let gpu = GPUContext.shared else { throw GPUFailure("GPU unavailable") }
    isRendering = true
    progress = 0
    error = nil
    counts = MovieCounts()
    keyframeLimits = []
    defer {
      isRendering = false
      stage = ""
    }
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    // HEVC where the hardware takes it, H.264 otherwise.
    func makeInput(_ codec: AVVideoCodecType) -> AVAssetWriterInput {
      let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
          AVVideoCodecKey: codec, AVVideoWidthKey: settings.width,
          AVVideoHeightKey: settings.height,
        ])
      input.expectsMediaDataInRealTime = false
      return input
    }
    var input = makeInput(.hevc)
    if !writer.canAdd(input) { input = makeInput(.h264) }
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: settings.width,
        kCVPixelBufferHeightKey as String: settings.height,
        kCVPixelBufferMetalCompatibilityKey as String: true,
      ])
    guard writer.canAdd(input) else { throw GPUFailure("The movie writer rejected its input") }
    writer.add(input)
    guard writer.startWriting() else {
      throw GPUFailure(writer.error.map { String(describing: $0) } ?? "The movie writer failed")
    }
    writer.startSession(atSourceTime: .zero)
    var cache: CVMetalTextureCache?
    CVMetalTextureCacheCreate(nil, nil, gpu.device, nil, &cache)
    guard let cache else { throw GPUFailure("No Metal texture cache for the movie") }

    let size = CGSize(width: settings.width, height: settings.height)
    // The viewer's own default, not a fixed 512 MiB: on a phone that was 3.4x
    // the whole viewer budget, asked for on top of the viewer's live cache, from
    // a sheet the phone can open.  A keyframe is rendered once and read straight
    // back, so a movie has far less to keep resident than a view being explored.
    let tiles = store ?? TileStore(budgetBytes: Self.defaultBudgetBytes)
    var keyframes: [Int: MTLTexture] = [:]
    func keyframe(_ index: Int) async throws -> MTLTexture {
      if let existing = keyframes[index] { return existing }
      let level = path.keyframeLevels[index]
      stage = "Keyframe \(index + 1) of \(path.keyframeLevels.count)"
      counts.keyframes = path.keyframeLevels.count
      counts.keyframe = index + 1
      counts.onKeyframe = true
      defer { counts.onKeyframe = false }
      let fraction =
        (level - path.startLog) / max(.leastNonzeroMagnitude, path.endLog - path.startLog)
      let view = path.viewport(at: level)
      var settingsForLevel: ColourSettings
      if let colourSchedule {
        settingsForLevel = colourSchedule.colouring(at: fraction, base: colouring)
      } else if settings.depthAdaptiveColour {
        settingsForLevel = DepthColouring.resolve(
          viewport: view, contrast: settings.densityAdjustment,
          offsetAdjustment: settings.offsetAdjustment, palette: colouring.palette,
          smooth: colouring.smooth)
      } else {
        settingsForLevel = colouring
      }
      if colourSchedule != nil || settings.depthAdaptiveColour {
        // The scheduled offset is already anchored to its sampled percentile;
        // depth-adaptive colour is too. Palette cycling is the only additional
        // phase movement.
        settingsForLevel.offset += Float(settings.paletteCycles * fraction)
      } else {
        // Preserve pre-2.11 movie output bit-for-bit for legacy locations.
        settingsForLevel.offset = Float(
          path.paletteOffset(at: level, cycles: settings.paletteCycles))
      }
      let limit = path.iterations(at: level)
      keyframeLimits.append((level, limit))
      tiles.update(
        viewport: view, size: size, pixelWidth: size.width,
        iterations: limit, override: nil, colouring: settingsForLevel)
      try await tiles.waitUntilReady()
      let texture = try await TileCompositor.snapshot(
        store: tiles, viewport: view, width: settings.width, height: settings.height,
        now: ProcessInfo.processInfo.systemUptime + TilePresentation.fadeDuration)
      // Only the pair in use stays resident; a long descent has hundreds.
      keyframes = keyframes.filter { $0.key >= index - 1 }
      keyframes[index] = texture
      return texture
    }

    let frames = settings.frameCount
    for frame in 0..<frames {
      try Task.checkCancellation()
      let time = Double(frame) / Double(frames - 1)
      let level = path.level(at: time)
      var index = 0
      while index + 2 < path.keyframeLevels.count && path.keyframeLevels[index + 1] <= level {
        index += 1
      }
      let lower = path.keyframeLevels[index]
      let upper = path.keyframeLevels[index + 1]
      let blend = upper > lower ? min(1, max(0, (level - lower) / (upper - lower))) : 0
      let first = try await keyframe(index)
      let second = try await keyframe(index + 1)
      let view = path.viewport(at: level)
      let a = Self.mapping(frame: view, keyframe: path.viewport(at: lower), size: size)
      let b = Self.mapping(frame: view, keyframe: path.viewport(at: upper), size: size)
      var uniforms = Uniforms(
        originA: a.origin, duA: a.du, dvA: a.dv, originB: b.origin, duB: b.du, dvB: b.dv,
        blend: Float(blend))
      while !input.isReadyForMoreMediaData {
        try await Task.sleep(for: .milliseconds(5))
      }
      guard let pool = adaptor.pixelBufferPool else {
        throw GPUFailure("The movie writer has no pixel buffers")
      }
      var buffer: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
      guard let buffer else { throw GPUFailure("Out of movie pixel buffers") }
      var metalTexture: CVMetalTexture?
      CVMetalTextureCacheCreateTextureFromImage(
        nil, cache, buffer, nil, .bgra8Unorm, settings.width, settings.height, 0, &metalTexture)
      guard let metalTexture, let target = CVMetalTextureGetTexture(metalTexture) else {
        throw GPUFailure("Could not draw into a movie frame")
      }
      let descriptor = MTLRenderPassDescriptor()
      descriptor.colorAttachments[0].texture = target
      descriptor.colorAttachments[0].loadAction = .clear
      descriptor.colorAttachments[0].storeAction = .store
      descriptor.colorAttachments[0].clearColor = MTLClearColor(
        red: 0.01, green: 0.01, blue: 0.02, alpha: 1)
      guard let command = gpu.displayQueue.makeCommandBuffer(),
        let encoder = command.makeRenderCommandEncoder(descriptor: descriptor)
      else { throw GPUFailure("GPU queue unavailable for the movie") }
      encoder.setRenderPipelineState(gpu.moviePipeline)
      encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
      encoder.setFragmentTexture(first, index: 0)
      encoder.setFragmentTexture(second, index: 1)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
      encoder.endEncoding()
      _ = try await gpu.submit(command)
      let stamp = CMTime(
        value: CMTimeValue(frame), timescale: CMTimeScale(settings.framesPerSecond))
      guard adaptor.append(buffer, withPresentationTime: stamp) else {
        throw GPUFailure(
          writer.error.map(\.localizedDescription) ?? "A movie frame was rejected")
      }
      progress = Double(frame + 1) / Double(frames)
      stage = "Frame \(frame + 1) of \(frames)"
      counts.frame = frame + 1
      counts.frames = frames
    }
    input.markAsFinished()
    await writer.finishWriting()
    if let failure = writer.error { throw GPUFailure(failure.localizedDescription) }
    tiles.cancel()
    output = url
    return url
  }

  /// Renders an arbitrary camera journey.  A direct descent keeps the much
  /// cheaper two-keyframe compositor above.  A journey containing lateral
  /// travel instead snapshots each output view: a pan is not contained by its
  /// neighbouring keyframe, so pretending it is would clamp and smear an edge
  /// across the movie.  The tile store keeps the overlapping work warm; this is
  /// deliberately the correct baseline before a panning compositor is added.
  func render(
    journey: Journey, settings: MovieSettings, colouring: ColourSettings, to url: URL,
    store: TileStore? = nil
  ) async throws -> URL {
    guard settings.duration >= journey.requestedDuration else {
      throw PrecisionError(
        "This journey needs at least \(Int(ceil(journey.requestedDuration))) seconds for a smooth camera move"
      )
    }
    let schedule = try await makeColourSchedule(
      for: journey, settings: settings, colouring: colouring)
    if journey.isDirectDescent {
      let path = try ZoomPath(
        start: journey.start, end: journey.end, eased: settings.eased)
      return try await render(
        path: path, settings: settings, colouring: colouring, to: url, store: store,
        colourSchedule: schedule)
    }
    guard let gpu = GPUContext.shared else { throw GPUFailure("GPU unavailable") }
    isRendering = true
    progress = 0
    error = nil
    counts = MovieCounts()
    keyframeLimits = []
    defer {
      isRendering = false
      stage = ""
    }
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    func makeInput(_ codec: AVVideoCodecType) -> AVAssetWriterInput {
      AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
          AVVideoCodecKey: codec, AVVideoWidthKey: settings.width,
          AVVideoHeightKey: settings.height,
        ])
    }
    var input = makeInput(.hevc)
    if !writer.canAdd(input) { input = makeInput(.h264) }
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: settings.width,
        kCVPixelBufferHeightKey as String: settings.height,
        kCVPixelBufferMetalCompatibilityKey as String: true,
      ])
    guard writer.canAdd(input) else { throw GPUFailure("The movie writer rejected its input") }
    writer.add(input)
    guard writer.startWriting() else {
      throw GPUFailure(writer.error?.localizedDescription ?? "The movie writer failed")
    }
    writer.startSession(atSourceTime: .zero)
    var cache: CVMetalTextureCache?
    CVMetalTextureCacheCreate(nil, nil, gpu.device, nil, &cache)
    guard let cache else { throw GPUFailure("No Metal texture cache for the movie") }

    let size = CGSize(width: settings.width, height: settings.height)
    let tiles = store ?? TileStore(budgetBytes: Self.defaultBudgetBytes)
    let frames = settings.frameCount
    for frame in 0..<frames {
      try Task.checkCancellation()
      let time = Double(frame) / Double(frames - 1)
      let view = try journey.viewport(
        at: time,
        duration: settings.duration,
        eased: settings.eased
      )
      let limit = journey.end.iterations ?? IterationPolicy.estimate(logScale: view.logScale)
      var frameColouring: ColourSettings
      if let schedule {
        frameColouring = schedule.colouring(at: time, base: colouring)
      } else if settings.depthAdaptiveColour {
        frameColouring = DepthColouring.resolve(
          viewport: view, contrast: settings.densityAdjustment,
          offsetAdjustment: settings.offsetAdjustment, palette: colouring.palette,
          smooth: colouring.smooth)
      } else {
        frameColouring = colouring
      }
      frameColouring.offset += Float(settings.paletteCycles * time)
      counts = MovieCounts(
        frame: frame, frames: frames, keyframe: frame + 1, keyframes: frames,
        onKeyframe: true)
      stage = "Journey frame \(frame + 1) of \(frames)"
      tiles.update(
        viewport: view, size: size, pixelWidth: size.width, iterations: limit, override: nil,
        colouring: frameColouring)
      try await tiles.waitUntilReady()
      let source = try await TileCompositor.snapshot(
        store: tiles, viewport: view, width: settings.width, height: settings.height,
        now: ProcessInfo.processInfo.systemUptime + TilePresentation.fadeDuration)
      while !input.isReadyForMoreMediaData {
        try await Task.sleep(for: .milliseconds(5))
      }
      guard let pool = adaptor.pixelBufferPool else {
        throw GPUFailure("The movie writer has no pixel buffers")
      }
      var buffer: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
      guard let buffer else { throw GPUFailure("Out of movie pixel buffers") }
      var metalTexture: CVMetalTexture?
      CVMetalTextureCacheCreateTextureFromImage(
        nil, cache, buffer, nil, .bgra8Unorm, settings.width, settings.height, 0, &metalTexture)
      guard let metalTexture, let target = CVMetalTextureGetTexture(metalTexture) else {
        throw GPUFailure("Could not draw into a movie frame")
      }
      guard let command = gpu.displayQueue.makeCommandBuffer(),
        let blit = command.makeBlitCommandEncoder()
      else { throw GPUFailure("GPU queue unavailable for the movie") }
      blit.copy(
        from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOriginMake(0, 0, 0),
        sourceSize: MTLSize(width: settings.width, height: settings.height, depth: 1), to: target,
        destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOriginMake(0, 0, 0))
      blit.endEncoding()
      _ = try await gpu.submit(command)
      let stamp = CMTime(
        value: CMTimeValue(frame), timescale: CMTimeScale(settings.framesPerSecond))
      guard adaptor.append(buffer, withPresentationTime: stamp) else {
        throw GPUFailure(writer.error?.localizedDescription ?? "A movie frame was rejected")
      }
      progress = Double(frame + 1) / Double(frames)
      counts.frame = frame + 1
      counts.onKeyframe = false
    }
    input.markAsFinished()
    await writer.finishWriting()
    if let failure = writer.error { throw GPUFailure(failure.localizedDescription) }
    tiles.cancel()
    output = url
    return url
  }
  /// Render a small, fixed set of planned camera positions before opening the
  /// writer. These are real escaped-count samples, not a heuristic based on
  /// scale, and include travel, rotation and holds through `Journey.viewport`.
  private func makeColourSchedule(
    for journey: Journey, settings: MovieSettings, colouring: ColourSettings
  ) async throws -> MovieColourSchedule? {
    guard settings.automaticColour else { return nil }
    let probes = min(17, max(5, Int(ceil(settings.duration)) + 1))
    let probeSize = CGSize(width: 320, height: 180)
    let tiles = TileStore(budgetBytes: 48 * 1024 * 1024)
    defer { tiles.cancel() }
    var stops: [MovieColourSchedule.Stop] = []
    for index in 0..<probes {
      try Task.checkCancellation()
      stage = "Analysing colour (index + 1) of (probes)"
      let time = Double(index) / Double(probes - 1)
      let view = try journey.viewport(at: time, duration: settings.duration, eased: settings.eased)
      let limit = journey.end.iterations ?? IterationPolicy.estimate(logScale: view.logScale)
      tiles.update(
        viewport: view, size: probeSize, pixelWidth: probeSize.width, iterations: limit,
        override: nil, colouring: colouring)
      try await tiles.waitUntilReady(timeout: .seconds(20))
      if let fit = AutomaticColourFit.resolve(
        histogram: tiles.visibleHistogram(), densityMultiplier: settings.densityAdjustment,
        offsetAdjustment: settings.offsetAdjustment)
      {
        stops.append(.init(time: time, fit: fit))
      }
    }
    return stops.isEmpty ? nil : MovieColourSchedule(stops: stops)
  }
  /// Renders in the background, reporting progress, for the sheet's button.
  func start(path: ZoomPath, settings: MovieSettings, colouring: ColourSettings, to url: URL) {
    task?.cancel()
    task = Task { [weak self] in
      guard let self else { return }
      do {
        _ = try await self.render(
          path: path, settings: settings, colouring: colouring, to: url)
      } catch is CancellationError {
        // A cancelled render never finished writing, so what is on disk is an
        // unplayable stub: take it away rather than leave it in the folder.
        try? FileManager.default.removeItem(at: url)
        self.error = nil
      } catch {
        // `String(describing:)` prints a whole NSError -- domain, code, nested
        // userInfo -- where the sentence people can act on is one field of it.
        self.error = error.localizedDescription
      }
    }
  }

  func start(journey: Journey, settings: MovieSettings, colouring: ColourSettings, to url: URL) {
    task?.cancel()
    task = Task { [weak self] in
      guard let self else { return }
      do {
        _ = try await self.render(
          journey: journey, settings: settings, colouring: colouring, to: url)
      } catch is CancellationError {
        try? FileManager.default.removeItem(at: url)
        self.error = nil
      } catch {
        self.error = error.localizedDescription
      }
    }
  }
}

#if DEBUG
  extension MovieRenderer {
    /// A renderer posed in one of the states the sheet draws, so a `#Preview` can
    /// show that state without a GPU or a render.  The published state is
    /// `private(set)` because only a render should move it, so a preview cannot
    /// set it from outside; this stays beside it, in the same file, for that.
    static func posed(
      progress: Double? = nil, stage: String = "", counts: MovieCounts = MovieCounts(),
      failure: String? = nil, output: URL? = nil
    ) -> MovieRenderer {
      let renderer = MovieRenderer()
      if let progress {
        renderer.isRendering = true
        renderer.progress = progress
        renderer.stage = stage
        renderer.counts = counts
      }
      renderer.error = failure
      renderer.output = output
      return renderer
    }
  }
#endif
