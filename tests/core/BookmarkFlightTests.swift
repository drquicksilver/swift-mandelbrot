import CoreGraphics
import Testing

@testable import MandelbrotCore

struct BookmarkFlightTests {
  let flight = BookmarkFlight(
    from: CGRect(x: 0, y: 52, width: 900, height: 600),
    to: CGRect(x: 700, y: 10, width: 28, height: 28))

  @Test func itStartsExactlyOverTheCanvas() {
    let first = flight.frame(at: 0)
    #expect(first.centre == CGPoint(x: 450, y: 352))
    #expect(first.size == CGSize(width: 900, height: 600))
    #expect(first.opacity == 1)
  }

  @Test func itEndsInsideThePlacesButtonAndGone() {
    let last = flight.frame(at: BookmarkFlight.duration)
    #expect(last.centre == CGPoint(x: 714, y: 24))
    #expect(last.opacity == 0)
    #expect(last.size.width < 28)
  }

  @Test func itOnlyEverShrinksAndNeverOvershoots() {
    var width = CGFloat.infinity
    var t = 0.0
    while t <= BookmarkFlight.duration {
      let frame = flight.frame(at: t)
      #expect(frame.size.width <= width + 1e-9, "Grew at \(t) s")
      width = frame.size.width
      // Never past the button, on either axis.
      #expect(frame.centre.x <= 714 + 1e-9)
      #expect(frame.centre.y >= 24 - 1e-9)
      #expect(abs(frame.rotationDegrees) <= BookmarkFlight.rotationDegrees)
      t += 0.005
    }
  }

  @Test func thePathIsContinuousAcrossThePhases() {
    for boundary in [BookmarkFlight.lift, BookmarkFlight.travelEnd] {
      let before = flight.frame(at: boundary - 1e-6)
      let after = flight.frame(at: boundary)
      #expect(hypot(before.centre.x - after.centre.x, before.centre.y - after.centre.y) < 0.5)
      #expect(abs(before.size.width - after.size.width) < 0.5)
    }
  }

  @Test func theCurveIsShallowAndArrivesFromBelow() {
    let start = CGPoint(x: 450, y: 352)
    let end = CGPoint(x: 714, y: 24)
    let middle = flight.point(on: start, end, at: 0.5)
    let chord = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
    // Below the straight line (larger y), and by only a little.
    #expect(middle.y > chord.y)
    let length = hypot(end.x - start.x, end.y - start.y)
    #expect(hypot(middle.x - chord.x, middle.y - chord.y) < length * 0.1)
  }
}
