import Foundation

/// The one way the app prints a zoom for people to read.  Grouped digits while
/// they still mean something, a short exponent once they stop: `1×`, `2.5×`,
/// `1,048,576×`, `3.4e27×`.  The exact decimal lives in a location's `scale`,
/// for links and bookmarks; nothing a person reads should show it.
enum ZoomFormat {
  /// Plain digits end at ten billion, where a count of digits starts to be
  /// easier than reading them.
  static let exponentThreshold = 1e10

  static func string(logScale: Double, locale: Locale = .current) -> String {
    guard logScale.isFinite else { return "—" }
    let zoom = pow(2, logScale)
    if zoom < 10 {
      // Below ten a fraction is the whole story: 0.5× is wider than the set.
      return zoom.formatted(.number.precision(.significantDigits(1...2)).locale(locale)) + "×"
    }
    if zoom < exponentThreshold {
      return zoom.formatted(
        .number.precision(.fractionLength(0)).grouping(.automatic).locale(locale)) + "×"
    }
    let decimal = logScale / log2(10)
    var exponent = Int(floor(decimal))
    var mantissa = (pow(10, decimal - Double(exponent)) * 10).rounded() / 10
    if mantissa >= 10 {
      // 9.96e20 rounds to 10.0: say 1.0e21 instead.
      mantissa /= 10
      exponent += 1
    }
    let digits = mantissa.formatted(.number.precision(.fractionLength(1)).locale(locale))
    return "\(digits)e\(exponent)×"
  }
}

extension Viewport {
  /// The zoom as a person reads it; `scaleDescription` is the exact form.
  var zoomDescription: String { ZoomFormat.string(logScale: logScale) }
}

extension Location {
  /// The zoom as a person reads it, or the stored text if it does not parse.
  var zoomDescription: String {
    guard let view = try? viewport() else { return scale + "×" }
    return view.zoomDescription
  }
}

extension Location {
  /// A name for a bookmark nobody named: the famous place it is close to, or
  /// failing that where it is, and either way how far in.  “Near Seahorse
  /// Valley · 4,000×” says more than any number alone.
  var suggestedName: String {
    let zoom = zoomDescription
    guard let x = Double(real), let y = Double(imag) else { return zoom }
    // Distance measured in the famous place's own view widths, so a deep
    // place only claims views that are close to it at its own scale.
    let nearby = Location.gallery.dropFirst().compactMap { place -> (String, Double)? in
      guard let px = Double(place.real), let py = Double(place.imag),
        let view = try? place.viewport()
      else { return nil }
      let widths = hypot(x - px, y - py) / (3 / pow(2, view.logScale))
      return widths < 2 ? (place.name, widths) : nil
    }
    if let nearest = nearby.min(by: { $0.1 < $1.1 }) {
      return String(localized: "Near \(nearest.0) · \(zoom)")
    }
    if let view = try? viewport(), view.logScale < 1 {
      return String(localized: "The whole set · \(zoom)")
    }
    let digits = FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...4))
    let sign = y < 0 ? "−" : "+"
    return "\(x.formatted(digits)) \(sign) \(abs(y).formatted(digits))i · \(zoom)"
  }
}
