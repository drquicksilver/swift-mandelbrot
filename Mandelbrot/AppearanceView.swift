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
        Section("Colours") {
          Picker("Palette", selection: $model.colouring.palette) {
            ForEach(Palette.allCases) { Text($0.title).tag($0) }
          }
          HStack(spacing: 0) {
            ForEach(0..<64, id: \.self) { index in
              let rgb = model.colouring.palette.rgb(Float(index) / 64)
              Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
            }
          }.frame(height: 32).clipShape(RoundedRectangle(cornerRadius: 8))
          ValueSlider("Colour spacing", value: $model.densityAdjustment.double, in: 0.25...4) {
            $0.formatted(.number.precision(.fractionLength(2))) + "×"
          }
          ValueSlider("Colour shift", value: $model.offsetAdjustment.double, in: -1...1) {
            $0.formatted(
              .number.precision(.fractionLength(2)).sign(strategy: .always(includingZero: false)))
          }
          Picker(
            "As you zoom",
            selection: Binding(
              get: { model.isDepthColouring ? 0 : 1 },
              set: { $0 == 0 ? model.useDepthColouring() : () })
          ) {
            Text("Match").tag(0)
            Text("Keep").tag(1)
          }.pickerStyle(.segmented)
          Button("Tune Colours to This View") { model.autoContrastThisView() }
            .disabled(!model.canAutoContrast)
          Text(
            model.isDepthColouring
              ? String(
                localized:
                  "Colours match the zoom, so a view looks the same every time you return to it.")
              : String(
                localized:
                  "These colours are kept as they are. Choose Match to let them follow the zoom again."
              )
          ).font(.caption)
        }
        Section("Detail") {
          Toggle("Automatic detail", isOn: $model.automaticIterations)
          if model.automaticIterations {
            ValueStepper(
              "Detail", value: $model.detailMultiplier, in: 0.25...16, step: 0.25, unit: "×")
          } else {
            TextField("Iterations", value: $model.manualIterations, format: .number)
            HStack {
              Button("Halve") { model.perform(.decreaseIterations) }
              Button("Double") { model.perform(.increaseIterations) }
            }.buttonStyle(.bordered)
          }
          Text("\(model.iterations.formatted()) iterations · maximum 1,000,000")
          Text(
            "Detail is how long each point is followed before it is counted as inside the set. Automatic detail rises as you zoom; raise it if parts of the view stay dark or blotchy."
          ).font(.caption)
        }
        Section("Julia companion") {
          #if os(macOS)
            Toggle("Crosshair follows the pointer", isOn: $model.juliaFollows)
          #else
            Toggle("Crosshair follows your finger", isOn: $model.juliaFollows)
          #endif
          Toggle("Pin the crosshair where it is", isOn: $model.juliaPinned)
          #if os(macOS)
            Text(
              "The crosshair on the Mandelbrot view marks the point the companion is drawn for. Drag it to move it, or click it to pin and release it. The companion has its own drag, pinch and twist."
            ).font(.caption)
          #else
            Text(
              "The crosshair on the Mandelbrot view marks the point the companion is drawn for. Drag it to move it, or tap it to pin and release it. The companion has its own drag, pinch and twist."
            ).font(.caption)
          #endif
        }
        Section("About") {
          Text("Mandelbrot")
          NavigationLink("Acknowledgements") { AcknowledgementsView() }
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
