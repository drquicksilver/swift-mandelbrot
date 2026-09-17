import Foundation

/// Automatic iteration depth.  A depth-based first estimate, lowered from the
/// escaped counts actually in view.  Raising from data needs interior detection
/// (periodicity checking, 2.10): without it a capped pixel may be inside the set
/// or merely unresolved.
enum IterationPolicy {
  static let maximum = 1_000_000
  static let minimum = 200
  /// Extra iterations per zoom level (a doubling of scale).
  ///
  /// No depth-only slope fits both kinds of deep location.  The c = i spiral at
  /// 1e1000 escapes within about 2,700 iterations, where this gives 266,000;
  /// the period-312 minibrot golden at 1e100 needs up to 60,000, where this
  /// gives about 26,800.  The slope stays generous: overshoot costs only
  /// interior pixels iterating to the limit, and the observed ceiling below
  /// removes it once the view settles, whereas undershoot draws escaping
  /// detail as the interior colour until the user raises detail.
  static let slope = 80.0
  static func estimate(logScale: Double, multiplier: Double = 1) -> Int {
    rounded((200 + slope * max(0, logScale)) * multiplier)
  }
  static func rounded(_ value: Double) -> Int {
    max(minimum, min(maximum, Int(ceil(min(Double(maximum), value) / 200)) * 200))
  }
  static func shouldLower(current: Int, target: Int) -> Bool {
    target < current && (target == minimum || current - target >= max(200, current / 10))
  }
  static func shouldRaise(current: Int, target: Int) -> Bool {
    target > current && (target == maximum || target - current >= max(200, current / 10))
  }

  /// A data-driven cap on the automatic limit: twice the highest escaped count
  /// observed in a settled view, at the depth it was observed.
  struct Ceiling: Equatable, Sendable {
    let base: Int
    let logScale: Double
  }
  /// Lowering is exact without interior detection.  Every pixel was computed to
  /// the current limit, so none escapes between the highest observed count and
  /// the limit, and capped pixels stay capped at twice that count.
  ///
  /// - Lower when the highest escaped count is below a quarter of the limit.
  /// - Release a ceiling once the view shows counts at least 1.5x those it was
  ///   derived from; new content may need the depth estimate again.
  static func observe(
    maximumEscaped: Int, limit: Int, logScale: Double, ceiling: Ceiling?
  ) -> Ceiling? {
    if maximumEscaped * 4 < limit {
      return Ceiling(base: rounded(Double(2 * maximumEscaped)), logScale: logScale)
    }
    if let ceiling, maximumEscaped * 4 >= ceiling.base * 3 { return nil }
    return ceiling
  }
  /// The automatic target: the depth estimate, capped by an observed ceiling
  /// that grows with further zoom at the estimate's slope.  The detail
  /// multiplier scales the estimate; it only ever widens the ceiling, so a
  /// reduced detail setting cannot starve the counts that release it.
  static func target(logScale: Double, multiplier: Double = 1, ceiling: Ceiling?) -> Int {
    let depth = estimate(logScale: logScale, multiplier: multiplier)
    guard let ceiling else { return depth }
    let grown =
      (Double(ceiling.base) + slope * max(0, logScale - ceiling.logScale)) * max(1, multiplier)
    return min(depth, rounded(grown))
  }
}
