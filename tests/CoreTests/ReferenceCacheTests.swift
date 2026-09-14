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

@Test func integerTileGeometryMatchesPreciseCoordinates() throws {
  let view = try Viewport(real: "-.743643887037151", imag: ".13182590390533", zoom: "1e1000")
  var grid = TileGrid(anchor: view.center)
  grid.rebase(to: view.preciseCenter)
  let size = CGSize(width: 900, height: 450)
  let origin = grid.bounds(TileKey(level: 3322, x: -2, y: -1, anchorID: grid.anchorID))
  let projection = TileProjection(origin: origin, viewport: view, size: size)
  for level in 3319...3324 {
    for x in -3...3 {
      let b = grid.bounds(TileKey(level: level, x: Int64(x), y: -1, anchorID: grid.anchorID))
      let actual = projection.center(of: b)
      let expected = view.screen(for: b.preciseCenter, in: size)
      #expect(abs(actual.x - expected.x) < 1e-9 && abs(actual.y - expected.y) < 1e-9)
    }
  }
}

@Test func escapedHighLimitReferenceDoesNotReserveTheWholeLimit() async throws {
  let cache = ReferenceOrbitCache(byteLimit: 4 * 1024 * 1024)
  let point = DeepPoint(CGPoint(x: 3, y: 0), bits: 256)
  let result = try await cache.reference(point: point, iterations: 1_000_000, bits: 256)
  #expect(result.0.escaped && result.0.values.count < 10)
  #expect(result.0.storageBytes < 1024 * 1024)
  #expect(await cache.bytes == result.0.storageBytes)
  let again = try await cache.reference(point: point, iterations: 1_000_000, bits: 256)
  #expect(again.1)
}
