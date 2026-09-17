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

@Test func decreaseHysteresis() {
  #expect(!IterationPolicy.shouldLower(current: 10000, target: 9800))
  #expect(IterationPolicy.shouldLower(current: 10000, target: 8800))
  #expect(IterationPolicy.shouldLower(current: 400, target: 200))
}

@Test func observedCeilingLowersExactlyAndReleases() {
  // Highest escaped count below a quarter of the limit: lower to twice it.
  let ceiling = IterationPolicy.observe(
    maximumEscaped: 1_300, limit: 266_000, logScale: 3322, ceiling: nil)
  #expect(ceiling == IterationPolicy.Ceiling(base: 2_600, logScale: 3322))
  #expect(IterationPolicy.target(logScale: 3322, ceiling: ceiling) == 2_600)
  // Settled at the lowered limit, the same counts neither lower nor release.
  #expect(
    IterationPolicy.observe(maximumEscaped: 1_300, limit: 2_600, logScale: 3322, ceiling: ceiling)
      == ceiling)
  // Counts 1.5x those observed release it, back to the depth estimate.
  #expect(
    IterationPolicy.observe(maximumEscaped: 1_950, limit: 2_600, logScale: 3322, ceiling: ceiling)
      == nil)
  // Zooming further grows the ceiling at the estimate's slope, never past it.
  #expect(IterationPolicy.target(logScale: 3332, ceiling: ceiling) == 3_400)
  #expect(
    IterationPolicy.target(logScale: 1, ceiling: ceiling)
      == IterationPolicy.estimate(logScale: 1))
  // The multiplier widens a ceiling but a reduced detail setting cannot shrink it.
  #expect(IterationPolicy.target(logScale: 3322, multiplier: 2, ceiling: ceiling) == 5_200)
  #expect(IterationPolicy.target(logScale: 3322, multiplier: 0.25, ceiling: ceiling) == 2_600)
  // Nothing escaped: the minimum.
  #expect(
    IterationPolicy.observe(maximumEscaped: 0, limit: 1_000, logScale: 10, ceiling: nil)?.base
      == IterationPolicy.minimum)
}
