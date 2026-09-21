import CoreGraphics
import Foundation

/// A camera route through the parameter plane.  A simple descent is one zoom
/// segment; locations which do not nest are joined by zooming out, travelling
/// at a shared overview, then zooming back in.
struct Journey: Sendable {
  enum Kind: String, Sendable {
    case zoom
    case travel
    case hold

    var title: String {
      switch self {
      case .zoom: "Zoom"
      case .travel: "Travel"
      case .hold: "Hold"
      }
    }
  }

  struct Segment: Sendable, Identifiable {
    let id: UUID
    var kind: Kind
    var from: Location
    var to: Location
    /// The shortest duration at which the camera remains readable.
    var minimumDuration: Double
    /// The editor's requested allocation for this segment.  It can lengthen a
    /// move, never make it faster than the safety minimum.
    var duration: Double
    /// An optional deliberate pause at a view.
    var holdDuration: Double

    init(
      kind: Kind, from: Location, to: Location, minimumDuration: Double,
      duration: Double? = nil,
      holdDuration: Double = 0, id: UUID = UUID()
    ) {
      self.id = id
      self.kind = kind
      self.from = from
      self.to = to
      self.minimumDuration = minimumDuration
      self.duration = max(minimumDuration, duration ?? minimumDuration)
      self.holdDuration = holdDuration
    }

    var minimum: Double { max(minimumDuration, holdDuration) }
    var requestedDuration: Double { max(minimum, duration) }
  }

  let start: Location
  let end: Location
  var segments: [Segment]

  /// About 2.4 octaves per second is quick but still lets a feature register.
  static let maximumZoomVelocity = 2.4
  /// A travel at the overview should not rush more than this many frame widths
  /// per second.  It is deliberately slower than a zoom: lateral motion is
  /// harder to follow in dense detail.
  static let maximumTravelVelocity = 0.7
  static let maximumRotationVelocity = Double.pi / 3
  /// A zoom can be easing away while a lateral travel begins, and vice versa.
  /// The overlap is deliberately modest: it removes the stop-start feel without
  /// making either movement hard to read on its own.
  static let easingOverlap = 0.22

  var minimumDuration: Double { schedule(segments.map(\.minimum)).total }
  var requestedDuration: Double { schedule(segments.map(\.requestedDuration)).total }
  var isDirectDescent: Bool { segments.count == 1 && segments[0].kind == .zoom }

  /// The casual-user planner.  Its only input is the two views and the movie's
  /// aspect ratio, so it is deterministic, easy to test, and equally available
  /// to the sheet and the CLI.
  static func planned(
    start: Location, end: Location, aspectRatio: Double = 16.0 / 9.0,
    overviewLogScale: Double? = nil
  ) throws -> Journey {
    let from = try start.viewport()
    let to = try end.viewport()
    guard aspectRatio.isFinite, aspectRatio > 0 else {
      throw PrecisionError("A journey needs a positive aspect ratio")
    }
    guard
      from.logScale != to.logScale || from.preciseCenter != to.preciseCenter
        || from.angle != to.angle
    else {
      throw PrecisionError("A journey needs two different views")
    }

    if contains(from, to, aspectRatio: aspectRatio), to.logScale > from.logScale + 0.5 {
      return Journey(
        start: start, end: end,
        segments: [zoom(from: start, to: end)])
    }

    // At the overview, keep the exit centred on the start and the entry
    // centred on the end.  The travel is therefore a real lateral camera move,
    // rather than an invisible slide baked into either zoom.
    var overview = sharedOverview(from: from, to: to, aspectRatio: aspectRatio)
    if let overviewLogScale {
      guard overviewLogScale <= overview.logScale + 1e-9 else {
        throw PrecisionError("The overview must be no tighter than the suggested shared view")
      }
      let centre = overview.preciseCenter
      overview = Viewport(center: centre.point, scale: pow(2, min(overviewLogScale, 1023)))
      if overviewLogScale > 30 {
        overview.deepCenter = centre
        overview.deepLogScale = overviewLogScale
      }
    }
    let exit = Location(
      viewport: Viewport(
        center: from.center, scale: pow(2, min(overview.logScale, 1023))),
      iterations: start.iterations, colouring: start.colouring, name: "Overview")
    let entry = Location(
      viewport: Viewport(
        center: to.center, scale: pow(2, min(overview.logScale, 1023))),
      iterations: end.iterations, colouring: end.colouring, name: "Overview")
    var exitView = try exit.viewport()
    var entryView = try entry.viewport()
    if overview.logScale > 30 {
      exitView.deepCenter = from.preciseCenter
      exitView.deepLogScale = overview.logScale
      entryView.deepCenter = to.preciseCenter
      entryView.deepLogScale = overview.logScale
    }
    let preciseExit = Location(
      viewport: exitView, iterations: start.iterations, colouring: start.colouring, name: "Overview"
    )
    let preciseEntry = Location(
      viewport: entryView, iterations: end.iterations, colouring: end.colouring, name: "Overview")
    return Journey(
      start: start, end: end,
      segments: [
        zoom(from: start, to: preciseExit),
        travel(from: preciseExit, to: preciseEntry, aspectRatio: aspectRatio),
        zoom(from: preciseEntry, to: end),
      ])
  }

  /// A view at normalised journey time.  The zoom and travel channels have
  /// separate clocks, so neighbouring segments overlap through their easing
  /// tails instead of visibly stopping at the shared overview.
  func viewport(at time: Double, duration: Double, eased: Bool = true) throws -> Viewport {
    if isDirectDescent {
      let path = try ZoomPath(start: start, end: end, eased: eased)
      return path.viewport(at: path.level(at: time))
    }
    let durations = allocatedDurations(total: duration)
    let timing = schedule(durations)
    let moment = min(1, max(0, time)) * timing.total
    let initial = try start.viewport()
    var centre = initial.preciseCenter
    var logScale = initial.logScale
    var angle = initial.angle

    for (segment, slot) in zip(segments, timing.slots) {
      guard moment >= slot.start else { continue }
      let rawProgress = min(1, max(0, (moment - slot.start) / slot.duration))
      let progress = eased ? Journey.ease(rawProgress) : rawProgress
      let from = try segment.from.viewport()
      let to = try segment.to.viewport()
      switch segment.kind {
      case .zoom:
        logScale = from.logScale + (to.logScale - from.logScale) * progress
        angle = Viewport.normalised(
          from.angle + Viewport.normalised(to.angle - from.angle) * progress)
      case .travel:
        let bits = max(from.precisionBits, to.precisionBits)
        centre = from.preciseCenter.offset(
          x: (to.preciseCenter.x - from.preciseCenter.x).wide * progress,
          y: (to.preciseCenter.y - from.preciseCenter.y).wide * progress, bits: bits)
      case .hold:
        break
      }
    }
    var view = Viewport(center: centre.point, scale: pow(2, min(logScale, 1023)))
    if logScale > 30 {
      view.deepCenter = centre
      view.deepLogScale = logScale
    }
    view.angle = angle
    return view
  }

  func allocatedDurations(total: Double) -> [Double] {
    let requested = requestedDuration
    guard total > requested else { return segments.map(\.requestedDuration) }
    let scale = total / max(requested, 0.001)
    return segments.map { $0.requestedDuration * scale }
  }

  private struct Timing: Sendable {
    var slots: [(start: Double, duration: Double)]
    var total: Double
  }

  private func schedule(_ durations: [Double]) -> Timing {
    var slots: [(start: Double, duration: Double)] = []
    for (index, duration) in durations.enumerated() {
      let safeDuration = max(0.001, duration)
      let overlap: Double
      if index > 0, overlaps(segments[index - 1].kind, segments[index].kind) {
        overlap = min(slots[index - 1].duration, safeDuration) * Self.easingOverlap
      } else {
        overlap = 0
      }
      let start = slots.last.map { $0.start + $0.duration - overlap } ?? 0
      slots.append((start, safeDuration))
    }
    return Timing(slots: slots, total: slots.last.map { $0.start + $0.duration } ?? 0)
  }

  private func overlaps(_ a: Kind, _ b: Kind) -> Bool {
    (a == .zoom && b == .travel) || (a == .travel && b == .zoom)
  }

  func description() -> String {
    if isDirectDescent { return "Zoom from \(start.label) into \(end.label)." }
    return "Zoom out from \(start.label), travel across the set, then descend to \(end.label)."
  }

  private static func contains(_ outer: Viewport, _ inner: Viewport, aspectRatio: Double) -> Bool {
    let point = outer.screen(
      for: inner.preciseCenter, in: CGSize(width: 1, height: 1 / aspectRatio))
    // Leave a little visible context around the destination, not merely its
    // centre on the last pixel of the first frame.
    return point.x >= 0.12 && point.x <= 0.88 && point.y >= 0.12 / aspectRatio
      && point.y <= 0.88 / aspectRatio
  }

  private static func sharedOverview(
    from: Viewport, to: Viewport, aspectRatio: Double
  ) -> Viewport {
    let dx = (to.preciseCenter.x - from.preciseCenter.x).wide.magnitude.double
    let dy = (to.preciseCenter.y - from.preciseCenter.y).wide.magnitude.double
    // 1.25 supplies framing around both centres.  The overview is at least an
    // octave wider than each endpoint, so the two zoom legs read as departures
    // and arrivals even for near neighbours.
    let span = max(
      3 / pow(2, min(from.logScale, to.logScale) - 1), 1.25 * 2 * dx,
      1.25 * 2 * dy / aspectRatio)
    let logScale = log2(3 / max(span, Double.leastNonzeroMagnitude))
    let bits = max(from.precisionBits, to.precisionBits)
    let midpoint = from.preciseCenter.offset(
      x: (to.preciseCenter.x - from.preciseCenter.x).wide * 0.5,
      y: (to.preciseCenter.y - from.preciseCenter.y).wide * 0.5, bits: bits)
    var view = Viewport(center: midpoint.point, scale: pow(2, min(logScale, 1023)))
    if logScale > 30 {
      view.deepCenter = midpoint
      view.deepLogScale = logScale
    }
    return view
  }

  private static func zoom(from: Location, to: Location) -> Segment {
    let a = try! from.viewport()
    let b = try! to.viewport()
    let duration = max(
      abs(b.logScale - a.logScale) / maximumZoomVelocity,
      abs(Viewport.normalised(b.angle - a.angle)) / maximumRotationVelocity, 0.4)
    return Segment(kind: .zoom, from: from, to: to, minimumDuration: duration)
  }

  private static func travel(from: Location, to: Location, aspectRatio: Double) -> Segment {
    let a = try! from.viewport()
    let b = try! to.viewport()
    let dx = (b.preciseCenter.x - a.preciseCenter.x).wide / a.wideSpan
    let dy = (b.preciseCenter.y - a.preciseCenter.y).wide / a.wideSpan
    let widths = hypot(dx, dy / aspectRatio)
    let duration = max(
      widths / maximumTravelVelocity,
      abs(Viewport.normalised(b.angle - a.angle)) / maximumRotationVelocity, 0.4)
    return Segment(kind: .travel, from: from, to: to, minimumDuration: duration)
  }
}

extension Journey.Segment {
  func viewport(at time: Double) throws -> Viewport {
    let a = try from.viewport()
    let b = try to.viewport()
    let t = Journey.ease(time)
    if kind == .hold { return a }
    let bits = max(a.precisionBits, b.precisionBits)
    let centre = a.preciseCenter.offset(
      x: (b.preciseCenter.x - a.preciseCenter.x).wide * t,
      y: (b.preciseCenter.y - a.preciseCenter.y).wide * t, bits: bits)
    let logScale = a.logScale + (b.logScale - a.logScale) * t
    var view = Viewport(center: centre.point, scale: pow(2, min(logScale, 1023)))
    if logScale > 30 {
      view.deepCenter = centre
      view.deepLogScale = logScale
    }
    view.angle = Viewport.normalised(a.angle + Viewport.normalised(b.angle - a.angle) * t)
    return view
  }
}

extension Journey {
  static func ease(_ time: Double) -> Double {
    let t = min(1, max(0, time))
    return t * t * (3 - 2 * t)
  }
}

extension Location {
  fileprivate var label: String { name.isEmpty ? "the starting view" : name }
}
