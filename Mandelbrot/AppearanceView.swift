import SwiftUI

struct AppearanceView: View {
  @ObservedObject var model: ExplorerModel
  @State private var versionTaps = 0
  @State private var showDeveloper = false
  @AppStorage("DeveloperToolsUnlocked") private var unlocked = false
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Form {
        Section("Colour") {
          Picker("Palette", selection: $model.colouring.palette) {
            ForEach(Palette.allCases) { Text($0.title).tag($0) }
          }
          HStack(spacing: 0) {
            ForEach(0..<64, id: \.self) { index in
              let rgb = model.colouring.palette.rgb(Float(index) / 64)
              Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
            }
          }.frame(height: 32).clipShape(RoundedRectangle(cornerRadius: 8))
          LabeledContent("Colour spacing", value: String(format: "%.0f", model.colouring.density))
          Slider(value: $model.colouring.density, in: 8...512)
          Text("Colour offset")
          Slider(value: $model.colouring.offset, in: 0...1)
        }
        Section("Detail") {
          Toggle("Automatic iteration limit", isOn: $model.automaticIterations)
          if model.automaticIterations {
            Stepper(
              "Detail ×\(model.detailMultiplier, specifier: "%.2g")",
              value: $model.detailMultiplier, in: 0.25...16, step: 0.25)
          } else {
            TextField("Iteration limit", value: $model.manualIterations, format: .number)
            HStack {
              Button("Halve") { model.perform(.decreaseIterations) }
              Button("Double") { model.perform(.increaseIterations) }
            }.buttonStyle(.bordered)
          }
          Text("\(model.iterations.formatted()) iterations · maximum 1,000,000")
          Text(
            "Automatic detail estimates a starting limit from zoom depth. Raise the detail multiplier if a region remains dark."
          ).font(.caption)
        }
        Section("About") {
          Text("Mandelbrot")
          Text(
            "Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")"
          )
          .accessibilityIdentifier("versionLabel")
          .onTapGesture {
            versionTaps += 1
            if versionTaps == 7 {
              unlocked = true
              showDeveloper = true
              versionTaps = 0
            }
          }
          if unlocked { Button("Developer tools") { showDeveloper = true } }
        }
      }.navigationTitle("Settings")
        .toolbar { Button("Done") { dismiss() } }
    }.sheet(isPresented: $showDeveloper) { DeveloperPanel(model: model) }
      .frame(minWidth: 320, idealWidth: 420, minHeight: 350)
  }
}
