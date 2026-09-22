import Foundation

/// A logarithmic histogram of escaped iteration counts. It deliberately contains
/// no cache identity: callers decide which currently visible pixels contribute.
struct EscapedHistogram: Equatable, Sendable {
  static let binCount = 256
  static let binsPerOctave = 8.0
  var bins = Array(repeating: 0.0, count: binCount)

  var total: Double { bins.reduce(0, +) }

  mutating func add(_ counts: [UInt32], weight: Double = 1) {
    guard weight > 0 else { return }
    for (index, count) in counts.enumerated() where index < bins.count {
      bins[index] += Double(count) * weight
    }
  }

  func percentile(_ fraction: Double) -> Double? {
    let total = total
    guard total > 0 else { return nil }
    let target = min(1, max(0, fraction)) * total
    var seen = 0.0
    for (index, count) in bins.enumerated() {
      seen += count
      if seen >= target {
        return pow(2, (Double(index) + 0.5) / Self.binsPerOctave)
      }
    }
    return pow(2, (Double(bins.count) - 0.5) / Self.binsPerOctave)
  }
}

/// The automatic base mapping before the user's density multiplier and phase
/// adjustment are applied. Six palette turns between robust low/high percentiles
/// retain structure at deep zoom without making shallow views needlessly flat.
struct AutomaticColourFit: Equatable, Sendable {
  var density: Float
  var offset: Float

  static func resolve(
    histogram: EscapedHistogram, densityMultiplier: Float = 1, offsetAdjustment: Float = 0
  ) -> Self? {
    guard let low = histogram.percentile(0.05), let high = histogram.percentile(0.95),
      high > low
    else { return nil }
    // Preserve the familiar shallow-view spacing.  Deep views need a wider
    // cycle; shallow ones should not suddenly acquire denser stripes merely
    // because automatic colour was enabled.
    let octaveSpan = log2(high) - log2(low)
    let density = Float(max(0.02, octaveSpan / 6)) / min(16, max(0.125, densityMultiplier))
    // Keep the low robust percentile at a stable, pleasant palette phase.
    return Self(density: density, offset: Float(0.12 - log2(low) / Double(density)) + offsetAdjustment)
  }
}

/// The normal explorer mapping.  It depends only on camera scale, never on
/// tile contents or the current iteration limit.  The calibrated anchor is a
/// deliberately modest exponential: deep zooms gain room without making a
/// locally unusual minibrot dictate everybody else's colours.
enum DepthColouring {
  static let phase: Float = 0.12

  static func anchor(logScale: Double) -> Double {
    // Calibrated around the familiar 64-iteration whole-set palette. One
    // octave in the anchor every 40 camera octaves keeps 1e100 readable while
    // retaining contrast in ordinary navigation.
    64 * exp2(max(-8, min(1024, logScale)) / 40)
  }

  static func resolve(
    viewport: Viewport, contrast: Float = 1, offsetAdjustment: Float = 0,
    palette: Palette = .blueGold, smooth: Bool = true
  ) -> ColourSettings {
    let density = 1 / (Double(min(16, max(0.125, contrast))) * exp2(viewport.logScale / 93))
    return ColourSettings(
      palette: palette, density: Float(density),
      offset: phase - Float(log2(anchor(logScale: viewport.logScale)) / density) + offsetAdjustment,
      smooth: smooth, logarithmic: true)
  }
}

/// A deterministic colour mapping for a movie.  Unlike live exploration this
/// is sampled before frames are rendered, then interpolated by movie time; a
/// slow or fast tile cache therefore cannot change an exported frame.
struct MovieColourSchedule: Equatable, Sendable {
  struct Stop: Equatable, Sendable {
    var time: Double
    var fit: AutomaticColourFit
  }
  var stops: [Stop]

  func colouring(at time: Double, base: ColourSettings) -> ColourSettings {
    guard let first = stops.first else { return base }
    let time = min(1, max(0, time))
    guard let last = stops.last, time > first.time else {
      var result = base
      result.density = first.fit.density
      result.offset = first.fit.offset
      return result
    }
    guard time < last.time else {
      var result = base
      result.density = last.fit.density
      result.offset = last.fit.offset
      return result
    }
    let upper = stops.firstIndex(where: { $0.time >= time }) ?? stops.endIndex - 1
    let lower = max(0, upper - 1)
    let a = stops[lower]
    let b = stops[upper]
    let fraction = (time - a.time) / max(.leastNonzeroMagnitude, b.time - a.time)
    // Density is perceived as a ratio, so interpolation is logarithmic.
    let density = exp(
      log(Double(a.fit.density)) * (1 - fraction) + log(Double(b.fit.density)) * fraction)
    var result = base
    result.density = Float(density)
    result.offset = a.fit.offset + (b.fit.offset - a.fit.offset) * Float(fraction)
    result.logarithmic = true
    return result
  }
}
