// The labelled slider and stepper that every numeric setting uses, in Settings
// and in both movie sheets, so no control in the app is an unlabelled track.

import SwiftUI

/// A slider that says what it sets, what it is set to and how far it goes:
/// the title and live value on one line, the bounds at either end.  Every
/// slider in the app is one of these, so none of them is a bare track.
struct ValueSlider: View {
  let title: LocalizedStringKey
  @Binding var value: Double
  let range: ClosedRange<Double>
  var step: Double? = nil
  let format: (Double) -> String

  init(
    _ title: LocalizedStringKey, value: Binding<Double>, in range: ClosedRange<Double>,
    step: Double? = nil, format: @escaping (Double) -> String
  ) {
    self.title = title
    self._value = value
    self.range = range
    self.step = step
    self.format = format
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text(title)
        Spacer()
        Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
      }
      slider
        .labelsHidden()
        .accessibilityLabel(Text(title))
        .accessibilityValue(format(value))
    }
  }

  @ViewBuilder private var slider: some View {
    let bounds = { (edge: Double) in Text(format(edge)).font(.caption).foregroundStyle(.secondary) }
    if let step {
      Slider(value: $value, in: range, step: step) {
        Text(title)
      } minimumValueLabel: {
        bounds(range.lowerBound)
      } maximumValueLabel: {
        bounds(range.upperBound)
      }
    } else {
      Slider(value: $value, in: range) {
        Text(title)
      } minimumValueLabel: {
        bounds(range.lowerBound)
      } maximumValueLabel: {
        bounds(range.upperBound)
      }
    }
  }
}

/// A stepper whose value is always on screen beside it, never folded into
/// its label.  The title sits on the leading edge like any form row; hide it
/// with `.labelsHidden()` where a grid already names the row.  On the Mac the
/// value can also be typed.
struct ValueStepper: View {
  let title: LocalizedStringKey
  @Binding var value: Double
  let range: ClosedRange<Double>
  var step: Double = 1
  /// A unit after the value, such as “s” or “×”; empty for a bare count.
  var unit: String = ""

  init(
    _ title: LocalizedStringKey, value: Binding<Double>, in range: ClosedRange<Double>,
    step: Double = 1, unit: String = ""
  ) {
    self.title = title
    self._value = value
    self.range = range
    self.step = step
    self.unit = unit
  }

  private var clamped: Binding<Double> {
    Binding(get: { value }, set: { value = min(range.upperBound, max(range.lowerBound, $0)) })
  }

  private var spoken: String {
    let number = value.formatted(.number.precision(.fractionLength(0...2)))
    // A symbol hugs its number, 1.5×; a word stands apart, 12 s.
    guard let first = unit.unicodeScalars.first else { return number }
    return CharacterSet.letters.contains(first) ? "\(number) \(unit)" : number + unit
  }

  var body: some View {
    LabeledContent {
      HStack(spacing: 6) {
        #if os(macOS)
          TextField(
            "", value: clamped, format: .number.precision(.fractionLength(0...2))
          )
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .frame(width: 56)
          .accessibilityLabel(Text(title))
          if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
        #else
          Text(spoken).monospacedDigit().foregroundStyle(.secondary)
        #endif
        Stepper(value: clamped, in: range, step: step) { Text(title) }
          .labelsHidden()
          .accessibilityLabel(Text(title))
          .accessibilityValue(spoken)
      }
    } label: {
      Text(title)
    }
  }
}

extension Binding where Value == Float {
  /// The value controls work in `Double`; the colour model keeps `Float`.
  var double: Binding<Double> {
    Binding<Double>(get: { Double(wrappedValue) }, set: { wrappedValue = Float($0) })
  }
}

#if DEBUG
  #Preview("Value controls") {
    @Previewable @State var spacing = 1.0
    @Previewable @State var seconds = 12.0
    Form {
      ValueSlider("Colour spacing", value: $spacing, in: 0.25...4) {
        "×" + $0.formatted(.number.precision(.fractionLength(2)))
      }
      ValueStepper("Duration", value: $seconds, in: 2...120, unit: "s")
    }
    .frame(width: 420)
  }
#endif
