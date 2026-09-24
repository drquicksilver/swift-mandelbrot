// Fixed-point and wide numbers: sub-Double offsets survive, signs and precision
// behave, deep navigation covers the right tiles, and deep coordinates print
// without passing through Double.

import Foundation
import Testing

@testable import MandelbrotCore

@Test func deepDecimalsRetainSubDoubleOffsets() throws {
  let a = try DeepNumber(decimal: "-2", bits: 3500)
  let epsilon = try DeepNumber(decimal: "1e-1000", bits: 3500)
  let b = a + epsilon
  #expect(b.double == a.double)
  #expect(abs((b - a).wide / epsilon.wide - 1) < 1e-14)
  #expect(abs((epsilon * epsilon).wide.double) == 0)  // outside chosen fixed-point precision
  let scaled = WideReal(log2: -1000 * log2(10))
  #expect(scaled.exponent < -3000)
  #expect(abs(scaled / epsilon.wide - 1) < 1e-12)
  #expect(throws: PrecisionError.self) { try DeepNumber(decimal: "nan", bits: 100) }
  #expect(throws: PrecisionError.self) { try DeepNumber(decimal: "1e999999", bits: 100) }
}
@Test func fixedPointSignsAndPrecision() {
  for value in [-2.0, -0.743643887037151, 0, 0.13182590390533, 2] {
    let a = DeepNumber(value, bits: 400)
    #expect(a.double == value)
    #expect(a.rounded(to: 4000).rounded(to: 400) == a)
    #expect(abs((a * a).double - value * value) < 1e-15)
  }
}

@Test func deepNavigationAndTileCoverage() throws {
  var view = try Viewport(real: "0", imag: "1", zoom: "1e1000")
  let size = CGSize(width: 900, height: 450)
  let point = CGPoint(x: 700, y: 123)
  let fixed = view.preciseComplex(at: point, in: size)
  view.zoom(by: 1.75, at: point, in: size, pixelWidth: 1800)
  let screen = view.screen(for: fixed, in: size)
  #expect(abs(screen.x - point.x) < 1e-9 && abs(screen.y - point.y) < 1e-9)
  let old = view.preciseCenter
  view.pan(by: CGSize(width: 90, height: -45), in: size)
  let moved = view.screen(for: old, in: size)
  #expect(abs(moved.x - 540) < 1e-9 && abs(moved.y - 180) < 1e-9)
  var grid = TileGrid(anchor: .zero)
  grid.rebase(to: view.preciseCenter)
  let level = Int(ceil(grid.idealLevel(viewport: view, pixelWidth: 900)))
  let visible = grid.visible(viewport: view, size: size, level: level)
  #expect(level > 3300 && !visible.isEmpty && visible.count <= 32)
  for key in visible {
    let r = grid.bounds(key).relative(to: grid.bounds(key.parent))
    #expect(abs(r.extent - 0.5) < 1e-14)
    #expect(r.x >= 0 && r.y >= 0 && r.x + r.extent <= 1 && r.y + r.extent <= 1)
    #expect(grid.bounds(key).intersects(viewport: view, size: size))
    #expect(key.ancestor(at: -2).level == -2)
  }
}

@Test func deepCoordinatesExportWithoutDoubleRounding() throws {
  let a = try DeepNumber(decimal: "-1.00000000000000000000000000000000000000001", bits: 3500)
  let b = try DeepNumber(decimal: a.decimalString, bits: 3500)
  #expect((a.raw - b.raw).magnitude <= 1)
  let view = try Viewport(real: "0", imag: "1", zoom: "1e1000")
  let decoded = try Viewport(real: "0", imag: "1", zoom: view.scaleDescription)
  #expect(abs(decoded.logScale - view.logScale) < 1e-10)
}
