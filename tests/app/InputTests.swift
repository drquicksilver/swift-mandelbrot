// The Mac's double-click rule: two clicks, in place, and no more.

import CoreGraphics
import Testing

@testable import Mandelbrot

#if os(macOS)
  /// AppKit counts a second press inside the double-click interval as a double
  /// click wherever it lands; `DoubleClick` also asks that both were clicks,
  /// close together.
  struct DoubleClickTests {
    let here = CGPoint(x: 100, y: 100)

    @Test func twoClicksInPlaceAreADoubleClick() {
      var clicks = DoubleClick()
      clicks.released(from: here, to: here)
      #expect(clicks.isDouble(clickCount: 2, at: CGPoint(x: 103, y: 103)))
    }

    @Test func twoClicksApartAreNot() {
      var clicks = DoubleClick()
      clicks.released(from: here, to: here)
      #expect(!clicks.isDouble(clickCount: 2, at: CGPoint(x: 106, y: 100)))
      #expect(!clicks.isDouble(clickCount: 2, at: CGPoint(x: 700, y: 400)))
    }

    @Test func aDragIsNotTheFirstClick() {
      var clicks = DoubleClick()
      clicks.released(from: here, to: CGPoint(x: 160, y: 100))
      #expect(!clicks.isDouble(clickCount: 2, at: CGPoint(x: 160, y: 100)))
    }

    @Test func aTripleClickDoesNotZoomAgain() {
      var clicks = DoubleClick()
      clicks.released(from: here, to: here)
      #expect(clicks.isDouble(clickCount: 2, at: here))
      clicks.released(from: here, to: here)
      #expect(!clicks.isDouble(clickCount: 3, at: here))
    }

    @Test func nothingBeforeTheFirstClick() {
      #expect(!DoubleClick().isDouble(clickCount: 2, at: here))
    }
  }
#endif
