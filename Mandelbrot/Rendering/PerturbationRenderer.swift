// Deep zoom on the GPU: perturbation against a high-precision reference orbit,
// accelerated by bilinear approximation, with rebasing and Pauldelbrot glitch
// detection.  One routine serves both a tile and a full frame: it prepares or
// borrows a reference, streams it to the GPU in extending prefixes, runs the
// `perturbTile` kernel in resumable batches, and re-references only the pixels
// that glitched.  The CPU mathematics is in Core/Precision.

import CoreGraphics
import Foundation
import Metal

struct PerturbationMetrics: Codable, Sendable {
  var referenceSeconds = 0.0
  var referenceExtensions = 0
  var referenceSteps = 0
  var maximumReferenceLength = 0
  var blaSeconds = 0.0
  var referenceCacheHits = 0
  var referenceBytes = 0
  var kernelSeconds = 0.0
  var references = 0
  var batches = 0
  var glitches = 0
  var avoidedGlitches = 0
  var rebases = 0
  var skippedIterations = 0
  var longestBLASkip = 0
  var longestBatchMS = 0.0
}
/// The pixels one perturbation pass covers: the centre of the top-left pixel
/// and the step to the next, in deep coordinates.
struct PerturbationRegion: Sendable {
  var preferredReference: DeepPoint? = nil
  let topLeft: DeepPoint
  let stepX: WideReal, stepY: WideReal
  let width: Int, height: Int, bits: Int
  func point(x: Int, y: Int) -> DeepPoint {
    topLeft.offset(x: stepX * Double(x), y: stepY * -Double(y), bits: bits)
  }
  init(viewport: Viewport, width: Int, height: Int) {
    self.width = width
    self.height = height
    bits = viewport.precisionBits
    // Pixel centres, as the tiles and every other GPU path sample.
    topLeft = viewport.preciseComplex(
      at: CGPoint(x: 0.5, y: 0.5), in: CGSize(width: width, height: height))
    stepX = viewport.wideSpan * (1 / Double(width))
    stepY = stepX
  }
  init(topLeft: DeepPoint, step: WideReal, width: Int, height: Int, bits: Int) {
    self.topLeft = topLeft
    stepX = step
    stepY = step
    self.width = width
    self.height = height
    self.bits = bits
  }
}
/// The `options` bits of `perturbTile`'s parameters.
private struct PerturbationOptions: OptionSet {
  let rawValue: UInt32
  static let bla = Self(rawValue: 1)
  static let rebasingOff = Self(rawValue: 2)
  static let hierarchicalBLA = Self(rawValue: 4)
  /// Extending samples copied from a lower limit: only capped pixels restart.
  static let extendCapped = Self(rawValue: 8)
  /// The reference orbit has escaped or reached the limit, so running off its
  /// end means rebasing rather than waiting for it to be extended.
  static let referenceComplete = Self(rawValue: 16)
}
/// Mirrors `PerturbParameters` in Perturbation.metal.
private struct PerturbationParameters {
  var origin: ExtendedComplex
  var stepX, stepY: ExtendedFloat
  var width, height, iterations, referenceCount: UInt32
  var start, count, pass: UInt32
  var options: PerturbationOptions
  var blaBase: UInt32
  var padding1: UInt32 = 0, padding2: UInt32 = 0, padding3: UInt32 = 0
}

extension GPUContext {
  /// One reference at a time; only glitched pixels are retried. Work is split into
  /// bounded GPU batches, with cancellation on both CPU and GPU boundaries.
  func perturb(
    into samples: MTLTexture, region: PerturbationRegion, iterations: Int, useBLA: Bool = true,
    useRebasing: Bool = true, hierarchicalBLA: Bool = true, resources: PerturbationResources? = nil,
    preserveEscaped: Bool = false, fixedBLARadius: Bool = false
  ) async throws
    -> PerturbationMetrics
  {
    var metrics = PerturbationMetrics()
    let pool = resources ?? PerturbationResources(referenceBudget: 4 * 1024 * 1024)
    let states = try pool.acquire(device: device, length: region.width * region.height * 48)
    defer { pool.recycle(states) }
    guard let flags = device.makeBuffer(length: 40, options: .storageModeShared) else {
      throw GPUFailure("Perturbation status allocation failed")
    }
    var referencePoint =
      region.preferredReference ?? region.point(x: region.width / 2, y: region.height / 2)
    for pass in 0..<16 {
      try Task.checkCancellation()
      let requestedPoint = referencePoint
      func reference(upTo limit: Int, prefix: ReferenceOrbit?) async throws -> (
        ReferenceOrbit, Bool
      ) {
        let point = prefix?.point ?? requestedPoint
        if pass == 0 && resources != nil {
          return try await pool.references.reference(
            point: point, iterations: limit, bits: region.bits,
            radius: prefix == nil ? region.stepX * Double(region.width * 4) : WideReal(0))
        }
        let task = Task.detached(priority: .userInitiated) {
          if let prefix { return try prefix.extended(to: limit) }
          return try ReferenceOrbit.compute(point: point, iterations: limit, bits: region.bits)
        }
        let result = try await withTaskCancellationHandler {
          try await task.value
        } onCancel: {
          task.cancel()
        }
        return (result, false)
      }
      // End prefixes on a BLA leaf boundary: do not split a 32-step jump.
      var (ref, hit) = try await reference(upTo: min(iterations, 4097), prefix: nil)
      metrics.references += 1
      func account(_ ref: ReferenceOrbit, _ hit: Bool) async {
        metrics.referenceSeconds += hit ? 0 : ref.seconds
        metrics.referenceSteps += hit ? 0 : ref.computedSteps
        metrics.referenceCacheHits += hit ? 1 : 0
        metrics.maximumReferenceLength = max(metrics.maximumReferenceLength, ref.values.count)
        metrics.referenceBytes = await pool.references.bytes
      }
      await account(ref, hit)
      let point = ref.point
      let far = region.point(x: region.width - 1, y: region.height - 1)
      let dx = max(
        abs((region.topLeft.x - point.x).wide / region.stepX),
        abs((far.x - point.x).wide / region.stepX))
      let dy = max(
        abs((region.topLeft.y - point.y).wide / region.stepX),
        abs((far.y - point.y).wide / region.stepX))
      let maximumDelta = region.stepX * (hypot(dx, dy) * 1.01)
      func upload(_ ref: ReferenceOrbit) async throws -> (MTLBuffer, MTLBuffer, BLATable, Int) {
        let task = Task.detached(priority: .userInitiated) {
          let start = ProcessInfo.processInfo.systemUptime
          let table =
            useBLA
            ? try BilinearApproximation.build(
              orbit: ref, maximumDelta: maximumDelta, iterations: iterations,
              mergeGuardBits: fixedBLARadius ? 0 : 5, jumpGuardBits: fixedBLARadius ? 5 : 0)
            : BilinearApproximation.disabled
          return (table, ProcessInfo.processInfo.systemUptime - start)
        }
        let (table, seconds) = try await withTaskCancellationHandler {
          try await task.value
        } onCancel: {
          task.cancel()
        }
        metrics.blaSeconds += seconds
        let count = min(ref.values.count, iterations + 1)
        guard
          let orbit = device.makeBuffer(
            bytes: ref.values, length: count * MemoryLayout<ExtendedComplex>.stride,
            options: .storageModeShared),
          let blas = device.makeBuffer(
            bytes: table.entries, length: table.entries.count * MemoryLayout<BLAEntry>.stride,
            options: .storageModeShared)
        else { throw GPUFailure("Reference/BLA allocation failed") }
        return (orbit, blas, table, count)
      }
      var (orbit, blas, table, referenceCount) = try await upload(ref)
      let words = flags.contents().bindMemory(to: UInt32.self, capacity: 10)
      words[0] = UInt32.max
      words[1] = 0
      let delta = DeepPoint(x: region.topLeft.x - point.x, y: region.topLeft.y - point.y)
      var p = PerturbationParameters(
        origin: ExtendedComplex(delta), stepX: ExtendedFloat(region.stepX),
        stepY: ExtendedFloat(region.stepY),
        width: UInt32(region.width), height: UInt32(region.height), iterations: UInt32(iterations),
        referenceCount: UInt32(referenceCount),
        start: 0, count: 8, pass: UInt32(pass),
        options: [
          useBLA ? .bla : [], useRebasing ? [] : .rebasingOff,
          hierarchicalBLA ? .hierarchicalBLA : [], preserveEscaped ? .extendCapped : [],
        ],
        blaBase: UInt32(table.leafOffset))
      let maximumBatch = min(128, max(1, Int(UInt32.max) / (32 * region.width * region.height)))
      var batch = min(8, maximumBatch)
      while true {
        try Task.checkCancellation()
        for index in 2...8 { words[index] = 0 }
        if ref.escaped || ref.iterations >= iterations {
          p.options.insert(.referenceComplete)
        } else {
          p.options.remove(.referenceComplete)
        }
        p.count = UInt32(batch)
        guard let command = computeQueue.makeCommandBuffer(),
          let encoder = command.makeComputeCommandEncoder()
        else { throw GPUFailure("Perturbation queue unavailable") }
        encoder.setTexture(samples, index: 0)
        encoder.setBytes(&p, length: MemoryLayout<PerturbationParameters>.stride, index: 0)
        encoder.setBuffer(orbit, offset: 0, index: 1)
        encoder.setBuffer(states, offset: 0, index: 2)
        encoder.setBuffer(flags, offset: 0, index: 3)
        encoder.setBuffer(blas, offset: 0, index: 4)
        dispatch(encoder, pipeline: perturbPipeline, width: region.width, height: region.height)
        encoder.endEncoding()
        let seconds = try await submit(command)
        metrics.batches += 1
        metrics.kernelSeconds += seconds
        metrics.longestBatchMS = max(metrics.longestBatchMS, seconds * 1000)
        metrics.avoidedGlitches += Int(words[5])
        metrics.rebases += Int(words[2])
        metrics.skippedIterations += Int(words[3]) + (Int(words[6]) << 32)
        metrics.longestBLASkip = max(metrics.longestBLASkip, Int(words[7]))
        p.start = 1  // State is initialised once, regardless of pauses and BLA work counts.
        if words[4] == 0 { break }
        if words[8] > 0 {
          let next = min(iterations, max(Int(words[8]), (ref.values.count - 2) * 2 + 1))
          (ref, hit) = try await reference(upTo: next, prefix: ref)
          metrics.referenceExtensions += 1
          await account(ref, hit)
          (orbit, blas, table, referenceCount) = try await upload(ref)
          p.referenceCount = UInt32(referenceCount)
          p.blaBase = UInt32(table.leafOffset)
        }
        batch = max(
          1, min(maximumBatch, Int(Double(p.count) * min(2, 0.001 / max(seconds, 0.00001)))))
      }
      metrics.glitches += Int(words[1])
      if words[0] == UInt32.max { return metrics }
      let index = Int(words[0])
      referencePoint = region.point(x: index % region.width, y: index / region.width)
    }
    throw GPUFailure(
      "Perturbation needs more than 16 references; reduce the viewport or increase precision")
  }
}
