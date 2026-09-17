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

@Test func rotatedConversionsRoundTripAndPinAnchors() throws {
  let size = CGSize(width: 800, height: 500)
  let points = [
    CGPoint(x: 0, y: 0), CGPoint(x: 800, y: 500), CGPoint(x: 123, y: 456),
    CGPoint(x: 400, y: 250),
  ]
  for degrees in [0.0, 15, 45, -30, 90, 179] {
    var shallow = Viewport(center: CGPoint(x: -0.4, y: 0.2), scale: 64)
    shallow.angle = Viewport.normalised(degrees * .pi / 180)
    var deep = try Viewport(real: "0", imag: "1", zoom: "1e40")
    deep.angle = shallow.angle
    for point in points {
      let back = shallow.screen(for: shallow.complex(at: point, in: size), in: size)
      #expect(abs(back.x - point.x) < 1e-9 && abs(back.y - point.y) < 1e-9)
      let deepBack = deep.screen(for: deep.preciseComplex(at: point, in: size), in: size)
      #expect(abs(deepBack.x - point.x) < 1e-6 && abs(deepBack.y - point.y) < 1e-6)
    }
    // Rotation, panning and zooming all keep the point under the anchor.
    for anchor in points {
      var turned = shallow
      let fixed = turned.complex(at: anchor, in: size)
      turned.rotate(by: 0.3, at: anchor, in: size)
      let after = turned.complex(at: anchor, in: size)
      #expect(abs(after.x - fixed.x) < 1e-12 && abs(after.y - fixed.y) < 1e-12)
      #expect(abs(Viewport.normalised(turned.angle - shallow.angle - 0.3)) < 1e-12)
      var zoomed = turned
      zoomed.zoom(by: 3, at: anchor, in: size, pixelWidth: 800)
      let zoomedPoint = zoomed.complex(at: anchor, in: size)
      #expect(abs(zoomedPoint.x - fixed.x) < 1e-12 && abs(zoomedPoint.y - fixed.y) < 1e-12)
      var deepTurned = deep
      let deepFixed = deepTurned.preciseComplex(at: anchor, in: size)
      deepTurned.rotate(by: -0.7, at: anchor, in: size)
      let deepAfter = deepTurned.preciseComplex(at: anchor, in: size)
      #expect((deepAfter.x - deepFixed.x).wide / deepTurned.wideSpan < 1e-9)
      #expect((deepAfter.y - deepFixed.y).wide / deepTurned.wideSpan < 1e-9)
    }
  }
  // Panning a rotated view moves along the screen, not along the plane's axes.
  var turned = Viewport(center: CGPoint(x: -0.5, y: 0), scale: 1)
  turned.angle = .pi / 2
  turned.pan(by: CGSize(width: 80, height: 0), in: size)
  // At 90 degrees, dragging right moves the view down the imaginary axis.
  #expect(abs(turned.center.x + 0.5) < 1e-12)
  #expect(abs(turned.center.y + 80 / 800 * 3) < 1e-12)
}

@Test func rotatedVisibleTilesCoverEveryScreenCorner() {
  var grid = TileGrid(anchor: CGPoint(x: -0.5, y: 0))
  let size = CGSize(width: 640, height: 400)
  for degrees in [0.0, 20, 45, -60, 135] {
    var view = Viewport(center: CGPoint(x: -0.4, y: 0.15), scale: 32)
    view.angle = Viewport.normalised(degrees * .pi / 180)
    let level = Int(ceil(grid.idealLevel(viewport: view, pixelWidth: 640)))
    let keys = Set(grid.visible(viewport: view, size: size, level: level))
    #expect(!keys.isEmpty)
    for corner in [
      CGPoint(x: 0.5, y: 0.5), CGPoint(x: 639.5, y: 0.5), CGPoint(x: 0.5, y: 399.5),
      CGPoint(x: 639.5, y: 399.5), CGPoint(x: 320, y: 200),
    ] {
      let point = view.complex(at: corner, in: size)
      let span = grid.span(at: level)
      let key = TileKey(
        level: level, x: Int64(floor((point.x - grid.anchor.x) / span)),
        y: Int64(floor((grid.anchor.y - point.y) / span)), anchorID: grid.anchorID)
      #expect(keys.contains(key))
    }
  }
}
