import Foundation
import Testing

@testable import MandelbrotCore

@Test func knownEscapeCounts() {
  for (real, expected) in [(0.0, 100), (-1.0, 100), (1.0, 3), (3.0, 1)] {
    let data = MandelbrotRenderer.iterations(
      width: 1, height: 1, center: CGPoint(x: real, y: 0),
      scale: 1, blockSize: 1,
      configuration: MandelbrotConfiguration(maxIterations: 100, baseSpan: 0))
    #expect(data.value(atX: 0, y: 0) == expected)
  }
}

@Test func parallelAndScalarAgreeAtOddDimensions() {
  let center = CGPoint(x: -0.5, y: 0)
  let reference = MandelbrotRenderer.iterations(
    width: 17, height: 9, center: center, scale: 1, blockSize: 1)
  let parallel = MandelbrotRenderer.iterationsParallel(
    width: 17, height: 9, center: center, scale: 1, blockSize: 1)
  for y in 0..<9 {
    for x in 0..<17 {
      #expect(reference.value(atX: x, y: y) == parallel.value(atX: x, y: y))
    }
  }
}

@Test func depthEstimateAndHysteresis() {
  #expect(IterationPolicy.estimate(logScale: 0) == 200)
  #expect(IterationPolicy.estimate(logScale: log2(1e100)) >= 26000)
  #expect(IterationPolicy.estimate(logScale: 1000 * log2(10)) > 65535)
  #expect(IterationPolicy.estimate(logScale: 13000, multiplier: 16) == 1_000_000)
  #expect(!IterationPolicy.shouldRaise(current: 10000, target: 10200))
  #expect(IterationPolicy.shouldRaise(current: 10000, target: 11200))
  #expect(IterationPolicy.shouldRaise(current: 990000, target: 1_000_000))
}
@Test func highCountRecordsPreserveCorrection() {
  let a = SampleRecord(iteration: 1_000_000, correction: 0.003)
  let b = SampleRecord(iteration: 1_000_000, correction: 0.02)
  #expect(a.legacyFloat == b.legacyFloat)  // Why combining them was unsafe.
  #expect(a.correction != b.correction)
  #expect(MemoryLayout<SampleRecord>.stride == 8)
  #expect(SampleRecord(iteration: SampleRecord.capped, correction: 0).legacyFloat == -1)
}
