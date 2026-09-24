// The geometry of the Mac's bookmark flight, as a pure function of time, so
// Places/BookmarkFeedback.swift can draw any frame and the tests can check
// every one.

import CoreGraphics
import Foundation

/// The bookmark animation, as numbers: a copy of the view lifts off the
/// canvas, travels on a shallow curve to the Places button while it shrinks
/// to a thumbnail, and tucks into it.  The canvas itself never moves.
///
/// Everything is a function of the time since the click, so a frame can be
/// drawn, previewed or tested at any instant, and nothing overshoots.
struct BookmarkFlight: Equatable, Sendable {
  /// The copy's first frame: exactly over the canvas.
  var from: CGRect
  /// The Places button it tucks into.
  var to: CGRect

  // Phases, in seconds from the click: the first design's 0.54 s, taken
  // 30% slower after seeing it run.
  static let pace = 1.3
  static let lift = 0.12 * pace
  static let travelEnd = 0.44 * pace
  static let duration = 0.54 * pace
  /// When the Places button starts to respond, before the copy reaches it.
  static let anticipation = 0.34 * pace
  /// The most the copy turns, halfway along; it arrives square.
  static let rotationDegrees = 30.0
  /// The width the copy has shrunk to when it arrives, before it tucks in.
  static let thumbnailWidth: CGFloat = 44
  /// How far the path bows from a straight line, as a share of its length.
  static let bow: CGFloat = 0.14

  /// One frame of the copy.
  struct Frame: Equatable, Sendable {
    var centre: CGPoint
    var size: CGSize
    var cornerRadius: CGFloat
    var shadowRadius: CGFloat
    var rotationDegrees: Double
    var opacity: Double
  }

  func frame(at t: Double) -> Frame {
    let start = CGPoint(x: from.midX, y: from.midY)
    let end = CGPoint(x: to.midX, y: to.midY)
    let aspect = from.height / max(1, from.width)
    let lifted = 0.96
    if t < Self.lift {
      // Lift: detach from the canvas without going anywhere.
      let p = Self.easeOut(max(0, t) / Self.lift)
      let scale = 1 - (1 - lifted) * p
      return Frame(
        centre: start, size: CGSize(width: from.width * scale, height: from.height * scale),
        cornerRadius: 4 + 10 * p, shadowRadius: 18 * p, rotationDegrees: 0, opacity: 1)
    }
    let thumbnail = CGSize(width: Self.thumbnailWidth, height: Self.thumbnailWidth * aspect)
    if t < Self.travelEnd {
      // Travel: a smooth start and stop along a curve that bows away from
      // the straight line, shrinking evenly in proportion rather than in
      // points, so it never looks as though it stalls at the small end.
      let u = Self.easeInOut((t - Self.lift) / (Self.travelEnd - Self.lift))
      let startWidth = from.width * lifted
      let width = exp(Self.mix(log(max(1, startWidth)), log(thumbnail.width), u))
      return Frame(
        centre: point(on: start, end, at: u), size: CGSize(width: width, height: width * aspect),
        cornerRadius: Self.mix(14, 6, u), shadowRadius: Self.mix(18, 6, u),
        rotationDegrees: -Self.rotationDegrees * sin(.pi * u), opacity: 1)
    }
    // Tuck: shrink and fade into the button.
    let v = Self.easeIn(min(1, (t - Self.travelEnd) / (Self.duration - Self.travelEnd)))
    let scale = 1 - 0.8 * v
    return Frame(
      centre: end, size: CGSize(width: thumbnail.width * scale, height: thumbnail.height * scale),
      cornerRadius: 6 * scale, shadowRadius: 6 * (1 - v), rotationDegrees: 0, opacity: 1 - v)
  }

  /// A quadratic curve whose control point sits off the middle of the
  /// straight line, on the side that makes it arrive from below: the copy
  /// rises into a toolbar rather than dropping onto it.
  func point(on start: CGPoint, _ end: CGPoint, at u: Double) -> CGPoint {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let length = max(1, hypot(dx, dy))
    var normal = CGPoint(x: -dy / length, y: dx / length)
    if normal.y < 0 { normal = CGPoint(x: -normal.x, y: -normal.y) }
    let control = CGPoint(
      x: (start.x + end.x) / 2 + normal.x * length * Self.bow,
      y: (start.y + end.y) / 2 + normal.y * length * Self.bow)
    let a = (1 - u) * (1 - u)
    let b = 2 * (1 - u) * u
    let c = u * u
    return CGPoint(
      x: a * start.x + b * control.x + c * end.x, y: a * start.y + b * control.y + c * end.y)
  }

  static func mix(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * t }
  static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
  static func easeIn(_ t: Double) -> Double { t * t }
  static func easeInOut(_ t: Double) -> Double {
    t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
  }
}
