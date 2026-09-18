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

/// Renders a zoom movie: one keyframe per zoom level straight from the tile
/// cache, then an exponential zoom composed by interpolating between the two
/// keyframes that bracket each frame.  Only two keyframes are ever resident.
@MainActor final class MovieRenderer: ObservableObject {
  @Published private(set) var progress = 0.0
  @Published private(set) var isRendering = false
  @Published private(set) var stage = ""
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
    store: TileStore? = nil
  ) async throws -> URL {
    guard let gpu = GPUContext.shared else { throw GPUFailure("GPU unavailable") }
    isRendering = true
    progress = 0
    error = nil
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
      var settingsForLevel = colouring
      settingsForLevel.offset = Float(
        path.paletteOffset(at: level, cycles: settings.paletteCycles))
      let view = try path.viewport(at: level)
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
      let lower = path.keyframeLevels[index], upper = path.keyframeLevels[index + 1]
      let blend = upper > lower ? min(1, max(0, (level - lower) / (upper - lower))) : 0
      let first = try await keyframe(index)
      let second = try await keyframe(index + 1)
      let view = try path.viewport(at: level)
      let a = Self.mapping(frame: view, keyframe: try path.viewport(at: lower), size: size)
      let b = Self.mapping(frame: view, keyframe: try path.viewport(at: upper), size: size)
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
          writer.error.map { String(describing: $0) } ?? "A movie frame was rejected")
      }
      progress = Double(frame + 1) / Double(frames)
      stage = "Frame \(frame + 1) of \(frames)"
    }
    input.markAsFinished()
    await writer.finishWriting()
    if let failure = writer.error { throw GPUFailure(String(describing: failure)) }
    tiles.cancel()
    output = url
    return url
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
        self.error = nil
      } catch {
        self.error = String(describing: error)
      }
    }
  }
}
