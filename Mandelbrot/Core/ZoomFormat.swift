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
