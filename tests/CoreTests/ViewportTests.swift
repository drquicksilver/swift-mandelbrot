import Foundation
import Testing

@testable import MandelbrotCore

@Test func screenComplexRoundTripAndAspect() {
  let view = Viewport(center: CGPoint(x: -0.74, y: 0.13), scale: 1e7)
  let size = CGSize(width: 900, height: 450)
  for point in [CGPoint.zero, CGPoint(x: 450, y: 225), CGPoint(x: 900, y: 450)] {
    let result = view.screen(for: view.complex(at: point, in: size), in: size)
    #expect(abs(result.x - point.x) < 0.000001)
    #expect(abs(result.y - point.y) < 0.000001)
  }
}
@Test func anchoredZoomAndPrecisionCap() {
  var view = Viewport()
  let size = CGSize(width: 900, height: 450)
  let anchor = CGPoint(x: 700, y: 100)
  let before = view.complex(at: anchor, in: size)
  view.zoom(by: 8, at: anchor, in: size, pixelWidth: 1800)
  let after = view.complex(at: anchor, in: size)
  #expect(abs(before.x - after.x) < 1e-14)
  #expect(abs(before.y - after.y) < 1e-14)
  let capped = view.zoom(by: 1e100, at: anchor, in: size, pixelWidth: 1800)
  #expect(!capped)
  #expect(view.deepCenter != nil)
  #expect(view.recommendedRenderer(pixelWidth: 1800) == .perturbation)
  #expect(view.logScale > 300)
  let invalid = view.zoom(by: .nan, at: anchor, in: size, pixelWidth: 1800)
  #expect(!invalid)
}
