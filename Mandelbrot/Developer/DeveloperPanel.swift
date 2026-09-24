import Combine
import SwiftUI

struct DeveloperPanel: View {
  @ObservedObject var model: ExplorerModel
  @Environment(\.dismiss) private var dismiss
  @State private var benchmarks = false
  var body: some View {
    NavigationStack {
      Form {
        Section("Rendering") {
          Picker("Override", selection: $model.rendererOverride) {
            Text("Automatic").tag(nil as RendererID?)
            ForEach(RendererID.allCases.filter(\.isGPU)) { Text($0.title).tag(Optional($0)) }
          }
          if let requested = model.rendererOverride, requested != model.renderer {
            Text("Deep views require perturbation; other overrides resume when you zoom out.").font(
              .caption)
          }
          Toggle("Show performance HUD", isOn: $model.showHUD)
          Toggle("Tile borders and levels", isOn: $model.showTileOverlay)
          Text(
            "Automatic: \(model.viewport.recommendedRenderer(pixelWidth:model.pixelWidth).title)"
          ).font(.caption)
        }
        Section("Measurements") {
          Button("Benchmarks") { benchmarks = true }
          Text(DeviceDescription.current).font(.caption)
        }
      }.navigationTitle("Developer")
        #if os(iOS)
          .toolbar { Button("Done") { dismiss() } }
        #endif
    }.frame(minWidth: 320, idealWidth: 480, minHeight: 320)
      .sheet(isPresented: $benchmarks) {
        BenchmarkView(viewport: model.viewport, iterations: model.iterations)
      }
  }
}

#if os(macOS)
  /// Which explorer the developer window inspects: the one most recently in
  /// front.  Weak, so a closed window's model is not kept alive by it.
  @MainActor final class ExplorerRegistry: ObservableObject {
    static let shared = ExplorerRegistry()
    weak var current: ExplorerModel? {
      willSet { objectWillChange.send() }
    }
  }

  /// The developer panel as a window of its own on the Mac, beside the view
  /// it measures rather than a sheet covering it.
  struct DeveloperWindow: View {
    static let id = "developer"
    @ObservedObject private var registry = ExplorerRegistry.shared
    var body: some View {
      if let model = registry.current {
        DeveloperPanel(model: model)
      } else {
        ContentUnavailableView(
          "No Mandelbrot Window", systemImage: "macwindow",
          description: Text("Open a Mandelbrot window to inspect it."))
      }
    }
  }
#endif
