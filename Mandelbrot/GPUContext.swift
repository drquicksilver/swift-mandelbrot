import CoreGraphics
import Foundation
import Metal

struct GPUFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}
struct GPUParameters {
  var realMin, imagMax, stepX, stepY: SIMD2<Float>
  var width, height, maxIterations, precision: UInt32
  var rowStart: UInt32 = 0
  var rowCount: UInt32
  var smooth: UInt32 = 0
  var padding: UInt32 = 0
  init(viewport: Viewport, width: Int, height: Int, iterations: Int, renderer: RendererID) {
    let span = viewport.span
    let imaginarySpan = span * Double(height) / Double(width)
    realMin = Self.split(viewport.center.x - span / 2)
    imagMax = Self.split(viewport.center.y + imaginarySpan / 2)
    stepX = Self.split(span / Double(max(1, width - 1)))
    stepY = Self.split(imaginarySpan / Double(max(1, height - 1)))
    self.width = UInt32(width)
    self.height = UInt32(height)
    maxIterations = UInt32(iterations)
    precision = renderer == .metal ? 0 : 1
    rowCount = UInt32(height)
  }
  static func split(_ value: Double) -> SIMD2<Float> {
    let hi = Float(value)
    return SIMD2(hi, Float(value - Double(hi)))
  }
}
struct GPUFrame {
  let samples: MTLTexture
  let colour: MTLTexture
  let kernelSeconds: Double
  let colourSeconds: Double
  var perturbation: PerturbationMetrics? = nil
}
struct DrawUniforms {
  var rect = SIMD4<Float>(-1, 1, 1, -1)
  var uv = SIMD4<Float>(0, 0, 1, 1)
  var opacity: Float = 1
  var blend: Float = 0
  var border: UInt32 = 0
  var level: UInt32 = 0
}

/// Metal objects are immutable after initialization; commands own their resources
/// until completion. There is no CPU waitUntilCompleted on the product path.
final class GPUContext: @unchecked Sendable {
  static let shared = try? GPUContext()
  let device: MTLDevice
  let computeQueue: MTLCommandQueue
  let displayQueue: MTLCommandQueue
  let summaryPipeline: MTLComputePipelineState
  let samplePipeline: MTLComputePipelineState
  let perturbPipeline: MTLComputePipelineState
  let resumePipeline: MTLComputePipelineState
  let mipPipeline: MTLComputePipelineState
  let colourPipeline: MTLComputePipelineState
  let juliaPipeline: MTLComputePipelineState
  let imagePipeline: MTLRenderPipelineState
  let tilePipeline: MTLRenderPipelineState
  let moviePipeline: MTLRenderPipelineState
  let library: MTLLibrary
  private let palettes: [Palette: MTLTexture]

  private init() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
      let display = device.makeCommandQueue(), let library = device.makeDefaultLibrary()
    else {
      throw GPUFailure("Metal is unavailable")
    }
    palettes = Dictionary(
      uniqueKeysWithValues: try Palette.allCases.map {
        ($0, try Self.makePaletteTexture($0, device: device))
      })
    self.device = device
    computeQueue = queue
    displayQueue = display
    self.library = library
    summaryPipeline = try device.makeComputePipelineState(
      function: library.makeFunction(name: "summariseSamples")!)
    samplePipeline = try device.makeComputePipelineState(
      function: library.makeFunction(name: "renderSamples")!)
    perturbPipeline = try device.makeComputePipelineState(
      function: library.makeFunction(name: "perturbTile")!)
    resumePipeline = try device.makeComputePipelineState(
      function: library.makeFunction(name: "resumeTile")!)
    mipPipeline = try device.makeComputePipelineState(
      function: library.makeFunction(name: "averageChildren")!)
    juliaPipeline = try device.makeComputePipelineState(
      function: library.makeFunction(name: "renderJulia")!)
    colourPipeline = try device.makeComputePipelineState(
      function: library.makeFunction(name: "colourSamples")!)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "quadVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "imageFragment")
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    descriptor.colorAttachments[0].isBlendingEnabled = true
    descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
    descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
    imagePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    descriptor.vertexFunction = library.makeFunction(name: "tileVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "tileFragment")
    tilePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    descriptor.vertexFunction = library.makeFunction(name: "movieVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "movieFragment")
    moviePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
  }
  func texture(width: Int, height: Int, format: MTLPixelFormat) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: format, width: width, height: height, mipmapped: false)
    descriptor.storageMode = .private
    descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
    guard let texture = device.makeTexture(descriptor: descriptor) else {
      throw GPUFailure("Not enough GPU memory")
    }
    return texture
  }
  func submit(_ command: MTLCommandBuffer) async throws -> Double {
    try await withCheckedThrowingContinuation { continuation in
      command.addCompletedHandler { result in
        if result.status == .completed {
          continuation.resume(returning: max(0, result.gpuEndTime - result.gpuStartTime))
        } else {
          continuation.resume(
            throwing: GPUFailure(result.error?.localizedDescription ?? "GPU command failed"))
        }
      }
      command.commit()
    }
  }
  func dispatch(
    _ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, width: Int, height: Int
  ) {
    encoder.setComputePipelineState(pipeline)
    let w = pipeline.threadExecutionWidth
    let h = min(8, pipeline.maxTotalThreadsPerThreadgroup / w)
    // Uniform groups work on devices without non-uniform dispatch support.
    // Every compute kernel bounds-checks before accessing samples or orbit state.
    encoder.dispatchThreadgroups(
      MTLSize(width: (width + w - 1) / w, height: (height + h - 1) / h, depth: 1),
      threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
  }
  func compute(into samples: MTLTexture, parameters: GPUParameters) async throws -> Double {
    guard let command = computeQueue.makeCommandBuffer(),
      let encoder = command.makeComputeCommandEncoder()
    else { throw GPUFailure("GPU queue unavailable") }
    var params = parameters
    encoder.setTexture(samples, index: 0)
    encoder.setBytes(&params, length: MemoryLayout<GPUParameters>.stride, index: 0)
    dispatch(
      encoder, pipeline: samplePipeline, width: Int(params.width), height: Int(params.rowCount))
    encoder.endEncoding()
    return try await submit(command)
  }
  /// One small Julia render: z starts at the pixel, c is the picked point.
  func julia(into samples: MTLTexture, viewport: Viewport, c: CGPoint, iterations: Int) async throws
    -> Double
  {
    guard let command = computeQueue.makeCommandBuffer(),
      let encoder = command.makeComputeCommandEncoder()
    else { throw GPUFailure("GPU queue unavailable") }
    struct JuliaParameters {
      var image: GPUParameters
      var cr: SIMD2<Float>
      var ci: SIMD2<Float>
      var centreR: SIMD2<Float>
      var centreI: SIMD2<Float>
      var cosAngle: Float
      var sinAngle: Float
    }
    let width = samples.width, height = samples.height
    // Pixel centres, as the tiles use; the kernel adds the half step.
    let span = viewport.span
    let imaginarySpan = span * Double(height) / Double(width)
    var image = GPUParameters(
      viewport: viewport, width: width, height: height, iterations: iterations,
      renderer: viewport.logScale > 18 ? .metalDouble : .metal)
    image.realMin = GPUParameters.split(viewport.center.x - span / 2)
    image.imagMax = GPUParameters.split(viewport.center.y + imaginarySpan / 2)
    image.stepX = GPUParameters.split(span / Double(width))
    image.stepY = GPUParameters.split(imaginarySpan / Double(height))
    image.smooth = 1
    // The kernel walks out from the centre so that it can rotate the offset, and
    // scales both axes by stepX, which square pixels make equal to stepY.
    var parameters = JuliaParameters(
      image: image, cr: GPUParameters.split(c.x), ci: GPUParameters.split(c.y),
      centreR: GPUParameters.split(viewport.center.x),
      centreI: GPUParameters.split(viewport.center.y),
      cosAngle: Float(cos(viewport.angle)), sinAngle: Float(sin(viewport.angle)))
    encoder.setTexture(samples, index: 0)
    encoder.setBytes(&parameters, length: MemoryLayout<JuliaParameters>.stride, index: 0)
    dispatch(encoder, pipeline: juliaPipeline, width: width, height: height)
    encoder.endEncoding()
    return try await submit(command)
  }
  func resume(
    into samples: MTLTexture, states: MTLBuffer, parameters: GPUParameters, start: Int, count: Int
  ) async throws -> Double {
    struct Work {
      var image: GPUParameters
      var start, count, padding0, padding1: UInt32
    }
    var work = Work(
      image: parameters, start: UInt32(start), count: UInt32(count), padding0: 0, padding1: 0)
    guard let command = computeQueue.makeCommandBuffer(),
      let encoder = command.makeComputeCommandEncoder()
    else { throw GPUFailure("GPU queue unavailable") }
    encoder.setTexture(samples, index: 0)
    encoder.setBuffer(states, offset: 0, index: 1)
    encoder.setBytes(&work, length: MemoryLayout<Work>.stride, index: 0)
    dispatch(encoder, pipeline: resumePipeline, width: samples.width, height: samples.height)
    encoder.endEncoding()
    return try await submit(command)
  }
  func copySamples(_ source: MTLTexture, into target: MTLTexture) async throws {
    guard let command = computeQueue.makeCommandBuffer(),
      let encoder = command.makeBlitCommandEncoder()
    else { throw GPUFailure("Sample copy unavailable") }
    encoder.copy(
      from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
      sourceSize: MTLSize(width: source.width, height: source.height, depth: 1), to: target,
      destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    encoder.endEncoding()
    _ = try await submit(command)
  }
  func sampleSummary(_ samples: MTLTexture) async throws -> (capped: Int, maximumEscaped: Int) {
    guard let buffer = device.makeBuffer(length: 8, options: .storageModeShared),
      let command = computeQueue.makeCommandBuffer(),
      let encoder = command.makeComputeCommandEncoder()
    else { throw GPUFailure("Sample summary unavailable") }
    buffer.contents().storeBytes(of: UInt64(0), as: UInt64.self)
    encoder.setTexture(samples, index: 0)
    encoder.setBuffer(buffer, offset: 0, index: 0)
    dispatch(encoder, pipeline: summaryPipeline, width: samples.width, height: samples.height)
    encoder.endEncoding()
    _ = try await submit(command)
    let words = buffer.contents().assumingMemoryBound(to: UInt32.self)
    return (Int(words[0]), Int(words[1]))
  }
  func average(children: [MTLTexture], parent: MTLTexture) async throws -> MTLTexture {
    precondition(children.count == 4)
    let output = try texture(width: 258, height: 258, format: .rgba8Unorm)
    guard let command = computeQueue.makeCommandBuffer(),
      let encoder = command.makeComputeCommandEncoder()
    else { throw GPUFailure("GPU queue unavailable") }
    for (index, child) in children.enumerated() { encoder.setTexture(child, index: index) }
    encoder.setTexture(parent, index: 4)
    encoder.setTexture(output, index: 5)
    dispatch(encoder, pipeline: mipPipeline, width: 258, height: 258)
    encoder.endEncoding()
    _ = try await submit(command)
    return output
  }
  func paletteTexture(_ palette: Palette) throws -> MTLTexture { palettes[palette]! }
  private static func makePaletteTexture(_ palette: Palette, device: MTLDevice) throws -> MTLTexture
  {
    let descriptor = MTLTextureDescriptor()
    descriptor.textureType = .type1D
    descriptor.width = 1024
    descriptor.pixelFormat = .rgba8Unorm
    descriptor.storageMode = .shared
    descriptor.usage = .shaderRead
    guard let texture = device.makeTexture(descriptor: descriptor) else {
      throw GPUFailure("Palette allocation failed")
    }
    let bytes = palette.lookupTable()
    bytes.withUnsafeBytes {
      texture.replace(
        region: MTLRegionMake1D(0, 1024), mipmapLevel: 0, withBytes: $0.baseAddress!,
        bytesPerRow: 4096)
    }
    return texture
  }
  func colour(
    _ samples: MTLTexture, into colour: MTLTexture, settings: ColourSettings = ColourSettings(),
    iterations: Int = Int(UInt32.max)
  ) async throws -> Double {
    guard let command = computeQueue.makeCommandBuffer(),
      let encoder = command.makeComputeCommandEncoder()
    else { throw GPUFailure("GPU queue unavailable") }
    struct Parameters {
      var density: Float
      var offset: Float
      var smooth: UInt32
      var limit: UInt32
    }
    var parameters = Parameters(
      density: settings.density, offset: settings.offset, smooth: settings.smooth ? 1 : 0,
      limit: UInt32(iterations))
    encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 0)
    encoder.setTexture(try paletteTexture(settings.palette), index: 2)
    encoder.setTexture(samples, index: 0)
    encoder.setTexture(colour, index: 1)
    dispatch(encoder, pipeline: colourPipeline, width: colour.width, height: colour.height)
    encoder.endEncoding()
    return try await submit(command)
  }
  func render(
    viewport: Viewport, width: Int, height: Int, iterations: Int, renderer: RendererID,
    settings: ColourSettings = ColourSettings(), useBLA: Bool = true, useRebasing: Bool = true,
    hierarchicalBLA: Bool = true, fixedBLARadius: Bool = false
  ) async throws -> GPUFrame {
    let samples = try texture(width: width, height: height, format: .rg32Uint)
    let colour = try texture(width: width, height: height, format: .rgba8Unorm)
    var parameters = GPUParameters(
      viewport: viewport, width: width, height: height, iterations: iterations, renderer: renderer)
    parameters.smooth = settings.smooth ? 1 : 0
    var metrics: PerturbationMetrics?
    let kernel: Double
    if renderer == .perturbation {
      metrics = try await perturb(
        into: samples, region: PerturbationRegion(viewport: viewport, width: width, height: height),
        iterations: iterations, useBLA: useBLA, useRebasing: useRebasing,
        hierarchicalBLA: hierarchicalBLA, fixedBLARadius: fixedBLARadius)
      kernel = metrics!.kernelSeconds
    } else {
      kernel = try await compute(into: samples, parameters: parameters)
    }
    let shading = try await self.colour(
      samples, into: colour, settings: settings, iterations: iterations)
    return GPUFrame(
      samples: samples, colour: colour, kernelSeconds: kernel, colourSeconds: shading,
      perturbation: metrics)
  }
  // Readback exists only for export and numerical tests, never for presentation.
  func readback(_ texture: MTLTexture) async throws -> Data {
    let pixelBytes = texture.pixelFormat == .rg32Uint ? 8 : 4
    let stride = (texture.width * pixelBytes + 255) / 256 * 256
    guard
      let buffer = device.makeBuffer(length: stride * texture.height, options: .storageModeShared),
      let command = computeQueue.makeCommandBuffer(), let encoder = command.makeBlitCommandEncoder()
    else { throw GPUFailure("Readback allocation failed") }
    encoder.copy(
      from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
      sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: buffer,
      destinationOffset: 0, destinationBytesPerRow: stride,
      destinationBytesPerImage: stride * texture.height)
    encoder.endEncoding()
    _ = try await submit(command)
    var data = Data(capacity: texture.width * texture.height * pixelBytes)
    for y in 0..<texture.height {
      data.append(
        buffer.contents().advanced(by: y * stride).assumingMemoryBound(to: UInt8.self),
        count: texture.width * pixelBytes)
    }
    return data
  }
  func image(_ texture: MTLTexture) async throws -> CGImage {
    var data = try await readback(texture)
    if texture.pixelFormat == .bgra8Unorm {
      data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
        for i in stride(from: 0, to: bytes.count, by: 4) {
          let b = bytes[i]
          bytes[i] = bytes[i + 2]
          bytes[i + 2] = b
        }
      }
    }
    guard let provider = CGDataProvider(data: data as CFData),
      let image = CGImage(
        width: texture.width, height: texture.height,
        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: texture.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { throw GPUFailure("Image export failed") }
    return image
  }
}
