import SwiftUI

struct AppearanceView: View {
  @ObservedObject var model: ExplorerModel
  @State private var versionTaps = 0
  @State private var showDeveloper = false
  @AppStorage("DeveloperToolsUnlocked") private var unlocked = false
  @Environment(\.dismiss) private var dismiss
  #if os(macOS)
    @Environment(\.openWindow) private var openWindow
  #endif
  var body: some View {
    NavigationStack {
      Form {
        Section("Colours") {
          Picker("Palette", selection: $model.colouring.palette) {
            ForEach(Palette.allCases) { Text($0.title).tag($0) }
          }
          PalettePreview(palette: model.colouring.palette)
            .frame(height: 32).clipShape(RoundedRectangle(cornerRadius: 8))
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
          HStack(spacing: 12) {
            AppIcon().frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
              Text("Mandelbrot").font(.headline)
              Text("© 2026 Jules Bean").font(.caption).foregroundStyle(.secondary)
            }
          }
          .accessibilityElement(children: .combine)
          Link(
            "Source Code on GitHub",
            destination: URL(string: "https://github.com/drquicksilver/swift-mandelbrot")!)
          NavigationLink("Acknowledgements") {
            // The page's own dismiss would only pop it, so it is handed the
            // sheet's: pushed, it had no way out but the back chevron.
            AcknowledgementsView(done: { dismiss() })
          }
          Text(
            "Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")"
          )
          .accessibilityIdentifier("versionLabel")
          .onTapGesture {
            versionTaps += 1
            if versionTaps == 7 {
              unlocked = true
              openDeveloper()
              versionTaps = 0
            }
          }
          if unlocked { Button("Developer Tools") { openDeveloper() } }
        }
      }.navigationTitle("Settings")
        .toolbar { Button("Done") { dismiss() } }
    }.sheet(isPresented: $showDeveloper) { DeveloperPanel(model: model) }
      .frame(minWidth: 320, idealWidth: 420, minHeight: 350)
  }
  /// A window beside the view on the Mac; a sheet on iPhone, where there is
  /// no beside.
  private func openDeveloper() {
    #if os(macOS)
      openWindow(id: DeveloperWindow.id)
    #else
      showDeveloper = true
    #endif
  }
}

/// One turn of a palette as the renderer draws it: a continuous gradient, not
/// the 64 flat bands it used to be.  The palettes interpolate linearly
/// between their stops, so evenly spaced gradient stops reproduce them, and
/// the samples also follow the one palette that is computed rather than
/// stopped.
struct PalettePreview: View {
  let palette: Palette
  var body: some View {
    let samples = 48
    let stops = (0...samples).map { index in
      let phase = Float(index) / Float(samples)
      // Phase 1 wraps to 0; ask for the colour just before it instead.
      let rgb = palette.rgb(min(phase, 0.99999))
      return Gradient.Stop(
        color: Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z)),
        location: CGFloat(phase))
    }
    LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
      .accessibilityHidden(true)
  }
}

/// The app's own icon, for About.
struct AppIcon: View {
  var body: some View {
    #if os(macOS)
      Image(nsImage: NSApplication.shared.applicationIconImage).resizable()
    #else
      if let name = Self.primaryIconName, let icon = UIImage(named: name) {
        Image(uiImage: icon).resizable().clipShape(RoundedRectangle(cornerRadius: 11))
      } else {
        Image(systemName: "app").resizable().foregroundStyle(.secondary)
      }
    #endif
  }
  #if os(iOS)
    /// iOS will not load "AppIcon" by name; the compiled icon's file names
    /// are in the bundle's Info.plist.
    private static var primaryIconName: String? {
      let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
      let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
      return (primary?["CFBundleIconFiles"] as? [String])?.last
    }
  #endif
}
