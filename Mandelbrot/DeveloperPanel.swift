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
            ForEach(RendererID.allCases) { Text($0.title).tag(Optional($0)) }
          }
          if model.viewport.logScale > 40 {
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
        .toolbar { Button("Done") { dismiss() } }
    }.frame(minWidth: 320, idealWidth: 480, minHeight: 320)
      .sheet(isPresented: $benchmarks) {
        BenchmarkView(viewport: model.viewport, iterations: model.iterations)
      }
  }
}
