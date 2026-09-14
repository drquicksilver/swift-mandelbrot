import Foundation
import Testing

@testable import MandelbrotCore

@Test func referenceBandsPrefixesAndConcurrentRequests() async throws {
  let cache = ReferenceOrbitCache(byteLimit: 8 * 1024 * 1024)
  let point = DeepPoint(CGPoint(x: 0, y: 1), bits: 800)
  async let first = cache.reference(point: point, iterations: 1000, bits: 400)
  async let second = cache.reference(point: point, iterations: 1000, bits: 401)
  let (a, b) = try await (first, second)
  #expect(a.0.bits == 512 && b.0.bits == 512)
  #expect(await cache.computations == 1)
  let short = try await cache.reference(point: point, iterations: 100, bits: 402)
  #expect(short.1 && short.0.iterations == 1000)
  let distant = point.offset(x: WideReal(log2: -300), y: WideReal(0), bits: 800)
  let near = try await cache.reference(
    point: distant, iterations: 100, bits: 400, radius: WideReal(log2: -299))
  #expect(near.1 && near.0.point == point)
  _ = try await cache.reference(point: point, iterations: 100, bits: 513)
  #expect(await cache.computations == 2)
  #expect(await cache.bytes <= 8 * 1024 * 1024)
}
@Test func precisionPolicyAgreesForViewportAndTiles() {
  for level in [0, 15, 32, 33, 40, 41, 3300] {
    let view = PrecisionPolicy.renderer(logScale: Double(level) - 1, pixelWidth: 512, center: .zero)
    let tile = PrecisionPolicy.renderer(logScale: Double(level), pixelWidth: 256, center: .zero)
    #expect(view == tile)
  }
  #expect(
    PrecisionPolicy.renderer(logScale: 41, pixelWidth: 256, center: .zero, override: .baseline)
      == .perturbation)
}
