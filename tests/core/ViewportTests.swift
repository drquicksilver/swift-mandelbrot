// The camera and the things built on it: conversions, anchored zoom and
// rotation, locations and links, the gallery, zoom paths and journeys, and the
// automatic colour mappings.

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

/// Deep zoom rebuilds the centre from the anchor rather than moving it, so a
/// rotated view has to rotate that offset too.  Measured on screen, where a
/// displacement is visible: the anchored point must stay under the cursor.
@Test func rotatedDeepZoomKeepsTheAnchorUnderTheCursor() throws {
  let size = CGSize(width: 800, height: 500)
  let anchors = [
    CGPoint(x: 700, y: 100), CGPoint(x: 0, y: 0), CGPoint(x: 400, y: 250),
    CGPoint(x: 123, y: 456),
  ]
  for degrees in [0.0, 45, -30, 90, 179] {
    for factor in [2.0, 0.5, 1.0, 64.0] {
      for zoom in ["1e40", "1e300", "1e1000"] {
        var view = try Viewport(real: "0", imag: "1", zoom: zoom)
        view.angle = Viewport.normalised(degrees * .pi / 180)
        for anchor in anchors {
          var zoomed = view
          let fixed = zoomed.preciseComplex(at: anchor, in: size)
          zoomed.zoom(by: factor, at: anchor, in: size, pixelWidth: 800)
          let after = zoomed.screen(for: fixed, in: size)
          #expect(abs(after.x - anchor.x) < 0.01)
          #expect(abs(after.y - anchor.y) < 0.01)
        }
      }
    }
  }
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

@Test func locationsSurviveLinksAndViewports() throws {
  // A deep, rotated, hand-tuned view survives the round trip to a link.
  var deep = try Viewport(real: "0", imag: "1", zoom: "1e1000")
  deep.angle = Viewport.normalised(37 * .pi / 180)
  let original = Location(
    viewport: deep, iterations: 5000,
    colouring: ColourSettings(palette: .fire, density: 512, offset: 0.25), name: "Deep spiral")
  let parsed = try Location(url: original.url)
  #expect(parsed.real == original.real && parsed.imag == original.imag)
  #expect(parsed.scale == original.scale && parsed.name == "Deep spiral")
  #expect(parsed.iterations == 5000 && parsed.palette == .fire)
  #expect(abs(parsed.rotationDegrees - 37) < 1e-9)
  #expect(parsed.colouring == original.colouring)
  // And the viewport it rebuilds is the same view, to well under a pixel.
  let rebuilt = try parsed.viewport()
  #expect(abs(rebuilt.logScale - deep.logScale) < 1e-9)
  #expect(abs(Viewport.normalised(rebuilt.angle - deep.angle)) < 1e-9)
  let size = CGSize(width: 800, height: 500)
  let screen = rebuilt.screen(for: deep.preciseCenter, in: size)
  #expect(abs(screen.x - 400) < 0.01 && abs(screen.y - 250) < 0.01)
  // Automatic depth stays automatic, and the default palette stays out of the link.
  let shallow = Location(viewport: Viewport(), iterations: nil)
  #expect(shallow.url.absoluteString == "mandelbrot://view?re=-0.5&im=0.0&zoom=1.0")
  let historic = try Location(url: shallow.url)
  #expect(historic.iterations == nil && historic.automaticColour != true)
  // New snapshot links carry both the resolved pair and the user's offsets.
  let automatic = Location(
    viewport: Viewport(), colouring: ColourSettings(density: 321, offset: -0.4),
    automaticColour: true, densityAdjustment: 1.5, offsetAdjustment: -0.2)
  let restoredAutomatic = try Location(url: automatic.url)
  #expect(restoredAutomatic.colouring == automatic.colouring)
  #expect(restoredAutomatic.automaticColour == true)
  #expect(restoredAutomatic.densityAdjustment == 1.5 && restoredAutomatic.offsetAdjustment == -0.2)
  let depth = Location(viewport: Viewport(), automaticColour: false)
  let restoredDepth = try Location(url: depth.url)
  #expect(restoredDepth.automaticColour == false)
  // Both kinds of new colouring count in octaves; a historic link counts
  // iterations, as it always did.
  #expect(restoredDepth.colouring.logarithmic && restoredAutomatic.colouring.logarithmic)
  #expect(!historic.colouring.logarithmic)
  // A universal-link form parses the same way.
  let web = try Location(
    url: URL(string: "https://example.com/mandelbrot/view?re=-0.5&im=0&zoom=1e6&rot=90")!)
  #expect(web.rotationDegrees == 90 && web.scale == "1e6")
  for bad in [
    "mandelbrot://view?re=-0.5&im=0", "mandelbrot://other?re=0&im=0&zoom=1",
    "https://example.com/nope?re=0&im=0&zoom=1", "mandelbrot://view?re=9&im=0&zoom=1",
    "mandelbrot://view?re=0&im=0&zoom=1e9999", "mandelbrot://view?re=0&im=0&zoom=1&palette=none",
    "mandelbrot://view?re=0&im=0&zoom=1&iter=0", "mandelbrot://view?re=0&im=0&zoom=1&rot=400",
    "mandelbrot://view?re=x&im=0&zoom=1",
  ] {
    #expect(throws: (any Error).self) { try Location(url: URL(string: bad)!) }
  }
}

@Test func galleryLocationsAreValidAndDistinct() throws {
  #expect(Location.gallery.count >= 8)
  var seen: Set<String> = []
  for place in Location.gallery {
    let view = try place.viewport()
    #expect(!place.name.isEmpty)
    #expect(abs(view.center.x) <= 4 && abs(view.center.y) <= 4)
    #expect(view.logScale >= Viewport.minimumLogScale(size: CGSize(width: 1600, height: 900)))
    #expect(try Location(url: place.url).real == place.real)
    #expect(seen.insert(place.name).inserted)
  }
}

@Test func zoomPathKeepsTheDestinationStill() throws {
  let start = Location(name: "Whole", real: "-0.5", imag: "0", scale: "1")
  let end = Location(
    name: "Deep", real: "-0.743643887037151", imag: "0.13182590420533", scale: "1e12",
    rotationDegrees: 20)
  let path = try ZoomPath(start: start, end: end)
  let size = CGSize(width: 640, height: 360)
  #expect(path.keyframeLevels.first == path.startLog)
  #expect(abs(path.keyframeLevels.last! - path.endLog) < 1e-9)
  // One keyframe per zoom level of 2x, and each is a level apart.
  #expect(path.keyframeLevels.count == Int(ceil(path.endLog - path.startLog)) + 1)
  for (a, b) in zip(path.keyframeLevels, path.keyframeLevels.dropFirst()) {
    #expect(b - a <= 1 + 1e-9 && b > a)
  }
  // The destination drifts gently to the centre and is always on screen: its
  // offset shrinks with the span rather than swinging about.
  let destination = try end.viewport().preciseCenter
  var previousOffset = Double.infinity
  for level in stride(from: path.startLog, through: path.endLog, by: 0.37) {
    let view = path.viewport(at: level)
    let screen = view.screen(for: destination, in: size)
    let offset = hypot(screen.x - 320, screen.y - 180)
    #expect(offset <= previousOffset + 1e-9)
    #expect(abs(screen.x - 320) <= 320 && abs(screen.y - 180) <= 180)
    #expect(abs(view.logScale - level) < 1e-9)
    previousOffset = offset
  }
  // It converges steadily rather than lurching at the end: half way through,
  // the destination is already most of the way to the centre.
  let middle = path.viewport(at: (path.startLog + path.endLog) / 2)
    .screen(for: destination, in: size)
  let first = path.viewport(at: path.startLog).screen(for: destination, in: size)
  #expect(
    hypot(middle.x - 320, middle.y - 180) < hypot(first.x - 320, first.y - 180) * 0.75)
  let arrival = path.viewport(at: path.endLog).screen(for: destination, in: size)
  #expect(abs(arrival.x - 320) < 0.01)
  // The ends are exactly the start and end views.
  let opening = path.viewport(at: path.startLog)
  #expect(abs(opening.center.x - -0.5) < 1e-9 && abs(opening.center.y) < 1e-9)
  #expect(opening.angle == 0)
  let last = path.viewport(at: path.endLog)
  #expect(abs(Viewport.normalised(last.angle - 20 * .pi / 180)) < 1e-9)
  #expect(abs((last.preciseCenter.x - destination.x).wide / last.wideSpan) < 1e-6)
  // Easing starts and ends gently but covers the whole path.
  #expect(path.level(at: 0) == path.startLog)
  #expect(abs(path.level(at: 1) - path.endLog) < 1e-9)
  #expect(path.level(at: 0.5) > path.startLog && path.level(at: 0.5) < path.endLog)
  #expect(path.level(at: 0.1) - path.startLog < (path.endLog - path.startLog) * 0.1)
  let linear = try ZoomPath(start: start, end: end, eased: false)
  let quarter = linear.startLog + (linear.endLog - linear.startLog) / 4
  #expect(abs(linear.level(at: 0.25) - quarter) < 1e-9)
  // Depth follows the automatic estimate unless the destination fixes it.
  #expect(path.iterations(at: 40) == IterationPolicy.estimate(logScale: 40))
  var fixed = end
  fixed.iterations = 1234
  #expect(try ZoomPath(start: start, end: fixed).iterations(at: 40) == 1234)
  // Palette cycling advances the phase with depth.
  #expect(path.paletteOffset(at: path.startLog, cycles: 3) == end.offset)
  #expect(abs(path.paletteOffset(at: path.endLog, cycles: 3) - (end.offset + 3)) < 1e-9)
  #expect(path.paletteOffset(at: path.endLog, cycles: 0) == end.offset)
  // A path needs somewhere to go.
  #expect(throws: (any Error).self) { try ZoomPath(start: end, end: end) }
}

@Test func zoomPathStaysPreciseAtExtremeDepth() throws {
  let deep = Location(
    real: "-0.743643887037158704752191506114774",
    imag: "0.131825904205311970493132056385139", scale: "1e100")
  let path = try ZoomPath(start: Location(real: "-0.5", imag: "0", scale: "1"), end: deep)
  #expect(path.keyframeLevels.count > 330)
  let destination = try deep.viewport().preciseCenter
  let size = CGSize(width: 320, height: 200)
  var last = Double.infinity
  for level in [50.0, 120, 250, path.endLog] {
    let view = path.viewport(at: level)
    let screen = view.screen(for: destination, in: size)
    let offset = hypot(screen.x - 160, screen.y - 100)
    #expect(offset <= last + 1e-9)
    #expect(view.deepCenter != nil)
    last = offset
  }
  // The last frame is the destination itself, to well under a pixel.
  #expect(last < 0.01)
}

@Test func journeyPlannerKeepsNestedDescentsSimpleAndRoutesSeparatePlaces() throws {
  let whole = Location.gallery[0]
  let seahorse = Location.gallery[1]
  let direct = try Journey.planned(start: whole, end: seahorse)
  #expect(direct.isDirectDescent)
  #expect(direct.segments.count == 1)

  // This is the failure mode the old sheet accepted: it treated a different,
  // deeper gallery place as a Seahorse descent merely because its scale grew.
  let unrelated = Location.gallery[3]
  let routed = try Journey.planned(start: seahorse, end: unrelated)
  #expect(!routed.isDirectDescent)
  #expect(routed.segments.map(\.kind) == [.zoom, .travel, .zoom])
  #expect(routed.minimumDuration > 1)
  #expect(routed.minimumDuration < routed.segments.reduce(0) { $0 + $1.minimum })
  let overview = try #require(
    routed.segments.first { $0.kind == .travel }?.from.viewport().logScale)
  let wider = try Journey.planned(
    start: seahorse, end: unrelated, overviewLogScale: overview - 2)
  #expect(wider.minimumDuration > routed.minimumDuration)
  let first = try routed.viewport(at: 0, duration: routed.minimumDuration)
  let last = try routed.viewport(at: 1, duration: routed.minimumDuration)
  let expectedFirst = try seahorse.viewport()
  let expectedLast = try unrelated.viewport()
  #expect(abs(first.logScale - expectedFirst.logScale) < 1e-9)
  #expect(abs(last.logScale - expectedLast.logScale) < 1e-9)
  #expect(abs((first.preciseCenter.x - expectedFirst.preciseCenter.x).wide.double) < 1e-12)
  #expect(abs((last.preciseCenter.y - expectedLast.preciseCenter.y).wide.double) < 1e-12)
}

@Test func automaticColourUsesRobustPercentilesAndPinsItsPhase() throws {
  var histogram = EscapedHistogram()
  var counts = Array(repeating: UInt32(0), count: EscapedHistogram.binCount)
  counts[80] = 10_000
  counts[96] = 10_000
  counts[255] = 1  // An outlier must not decide the fit.
  histogram.add(counts)
  let fit = try #require(AutomaticColourFit.resolve(histogram: histogram))
  // Since 2.11 the fit is in log space: six palette turns across the octaves
  // between the robust percentiles, with the low one at phase 0.12.
  let octaves = (96 - 80) / EscapedHistogram.binsPerOctave
  #expect(abs(Double(fit.density) - octaves / 6) < 0.01)
  let low = pow(2, (80.5) / EscapedHistogram.binsPerOctave)
  #expect(abs(log2(low) / Double(fit.density) + Double(fit.offset) - 0.12) < 0.02)
}

@Test func depthColouringIsDeterministicAndIndependentOfIterationLimit() {
  let view = Viewport(center: CGPoint(x: -0.74, y: 0.13), scale: 1e20)
  let first = DepthColouring.resolve(viewport: view, contrast: 1.5)
  let second = DepthColouring.resolve(viewport: view, contrast: 1.5)
  #expect(first == second && first.logarithmic)
  var deeper = view
  deeper.zoom(
    by: 2, at: CGPoint(x: 0.5, y: 0.5), in: CGSize(width: 1, height: 1), pixelWidth: 1)
  #expect(DepthColouring.resolve(viewport: deeper, contrast: 1.5) != first)
}
