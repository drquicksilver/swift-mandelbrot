import Foundation
import Testing

@testable import MandelbrotCore

private let english = Locale(identifier: "en_GB")

@Test func zoomReadsAsDigitsThenExponent() {
  let cases: [(Double, String)] = [
    (0, "1×"), (-1, "0.5×"), (log2(2.5), "2.5×"), (log2(1_048_576), "1,048,576×"),
    // The audit found this printed as 2.0000000000000004e9×.
    (log2(2e9), "2,000,000,000×"),
    (log2(1.5e10), "1.5e10×"), (log2(3.4e27), "3.4e27×"),
    // A mantissa that rounds up carries into the exponent.
    (log2(9.97e20), "1.0e21×"),
  ]
  for (logScale, expected) in cases {
    #expect(ZoomFormat.string(logScale: logScale, locale: english) == expected)
  }
}

@Test func zoomFollowsTheLocale() {
  let german = Locale(identifier: "de_DE")
  #expect(ZoomFormat.string(logScale: log2(1_048_576), locale: german) == "1.048.576×")
  #expect(ZoomFormat.string(logScale: log2(2.5), locale: german) == "2,5×")
}

@Test func zoomOfALocationIgnoresItsExactDecimal() {
  let place = Location(real: "-0.75", imag: "0.1", scale: "2.0000000000000004e9")
  #expect(place.zoomDescription(locale: english) == "2,000,000,000×")
  #expect(ZoomFormat.string(logScale: .nan) == "—")
}

@Test func anUnnamedBookmarkIsNamedForWhereItIs() {
  let seahorse = Location.gallery[1]
  var nearby = seahorse
  nearby.scale = "8e3"
  #expect(nearby.suggestedName(locale: english) == "Near Seahorse Valley · 8,000×")
  #expect(Location.gallery[0].suggestedName(locale: english) == "The whole set · 1×")
  let elsewhere = Location(real: "-0.2", imag: "-0.7", scale: "50")
  // True minus signs on both parts.
  #expect(elsewhere.suggestedName(locale: english) == "−0.2 − 0.7i · 50×")
}

@Test func journeysAreDescribedByTheirPlaces() throws {
  let here = Location(real: "0.2821", imag: "0.01", scale: "2e3")
  let nested = try Journey.planned(start: Location.gallery[0], end: here)
  #expect(nested.description() == "Zoom from “The whole set” into this view.")
  #expect(nested.summary == "A single zoom")
  let apart = try Journey.planned(start: Location.gallery[1], end: here)
  #expect(apart.summary == "3 parts")
  #expect(
    apart.segments.map { apart.title(of: $0) } == [
      "Out from “Seahorse Valley”", "Across the set", "In to this view",
    ])
  #expect(!apart.description().contains("starting view"))
}
