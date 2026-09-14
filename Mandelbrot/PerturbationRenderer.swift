import CoreGraphics
import Foundation
import Metal

struct PerturbationMetrics: Codable, Sendable {
  var referenceSeconds = 0.0
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
    topLeft = viewport.preciseComplex(at: .zero, in: CGSize(width: width, height: height))
    stepX = viewport.wideSpan * (1 / Double(max(1, width - 1)))
    stepY = viewport.wideSpan * (Double(height) / Double(width) / Double(max(1, height - 1)))
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
private struct PerturbationParameters {
  var origin: ExtendedComplex
  var stepX, stepY: ExtendedFloat
  var width, height, iterations, referenceCount: UInt32
  var start, count, pass, padding: UInt32
  var blaBase: UInt32
  var padding1: UInt32 = 0, padding2: UInt32 = 0, padding3: UInt32 = 0
}

extension GPUContext {
  /// One reference at a time; only glitched pixels are retried. Work is split into
  /// bounded GPU batches, with cancellation on both CPU and GPU boundaries.
  func perturb(
    into samples: MTLTexture, region: PerturbationRegion, iterations: Int, useBLA: Bool = true,
    useRebasing: Bool = true, hierarchicalBLA: Bool = true, resources: PerturbationResources? = nil
  ) async throws
    -> PerturbationMetrics
  {
    var metrics = PerturbationMetrics()
    let pool = resources ?? PerturbationResources(referenceBudget: 4 * 1024 * 1024)
    let states = try pool.acquire(device: device, length: region.width * region.height * 48)
    defer { pool.recycle(states) }
    guard let flags = device.makeBuffer(length: 32, options: .storageModeShared) else {
      throw GPUFailure("Perturbation status allocation failed")
    }
    var referencePoint =
      region.preferredReference ?? region.point(x: region.width / 2, y: region.height / 2)
    for pass in 0..<16 {
      try Task.checkCancellation()
      let requestedPoint = referencePoint
      let task = Task.detached(priority: .userInitiated) {
        let reference: ReferenceOrbit
        let hit: Bool
        if pass == 0 && resources != nil {
          (reference, hit) = try await pool.references.reference(
            point: requestedPoint, iterations: iterations, bits: region.bits,
            radius: region.stepX * Double(region.width * 4))
        } else {
          reference = try ReferenceOrbit.compute(
            point: requestedPoint, iterations: iterations, bits: region.bits)
          hit = false
        }
        let point = reference.point
        let start = ProcessInfo.processInfo.systemUptime
        let far = region.point(x: region.width - 1, y: region.height - 1)
        let dx = max(
          abs((region.topLeft.x - point.x).wide / region.stepX),
          abs((far.x - point.x).wide / region.stepX))
        let dy = max(
          abs((region.topLeft.y - point.y).wide / region.stepX),
          abs((far.y - point.y).wide / region.stepX))
        let table =
          useBLA
          ? try BilinearApproximation.build(
            orbit: reference, maximumDelta: region.stepX * (hypot(dx, dy) * 1.01),
            iterations: iterations) : BilinearApproximation.disabled
        return (reference, hit, table, ProcessInfo.processInfo.systemUptime - start)
      }
      let (reference, hit, table, blaSeconds) = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      metrics.referenceSeconds += hit ? 0 : reference.seconds
      metrics.referenceCacheHits += hit ? 1 : 0
      metrics.blaSeconds += blaSeconds
      metrics.references += 1
      metrics.referenceBytes = await pool.references.bytes
      let point = reference.point
      let referenceCount = min(reference.values.count, iterations + 1)
      guard
        let orbit = device.makeBuffer(
          bytes: reference.values,
          length: referenceCount * MemoryLayout<ExtendedComplex>.stride,
          options: .storageModeShared)
      else { throw GPUFailure("Reference allocation failed") }
      guard
        let blas = device.makeBuffer(
          bytes: table.entries, length: table.entries.count * MemoryLayout<BLAEntry>.stride,
          options: .storageModeShared)
      else { throw GPUFailure("BLA allocation failed") }
      let words = flags.contents().bindMemory(to: UInt32.self, capacity: 8)
      words[0] = UInt32.max
      words[1] = 0
      words[2] = 0
      words[3] = 0
      let delta = DeepPoint(x: region.topLeft.x - point.x, y: region.topLeft.y - point.y)
      var p = PerturbationParameters(
        origin: ExtendedComplex(delta), stepX: ExtendedFloat(region.stepX),
        stepY: ExtendedFloat(region.stepY),
        width: UInt32(region.width), height: UInt32(region.height), iterations: UInt32(iterations),
        referenceCount: UInt32(referenceCount),
        start: 0, count: 8, pass: UInt32(pass),
        padding: (useBLA ? 1 : 0) | (useRebasing ? 0 : 2) | (hierarchicalBLA ? 4 : 0),
        blaBase: UInt32(table.leafOffset))
      let maximumBatch = min(128, max(1, Int(UInt32.max) / (32 * region.width * region.height)))
      var batch = min(8, maximumBatch)
      while p.start < iterations {
        try Task.checkCancellation()
        words[2] = 0
        words[3] = 0
        words[4] = 0
        words[5] = 0
        words[6] = 0
        words[7] = 0
        p.count = UInt32(min(batch, iterations - Int(p.start)))
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
        p.start += p.count
        if words[4] == 0 { break }
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
