import SwiftUI

struct ContentView: View {
  @StateObject private var model = ExplorerModel()
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.displayScale) private var displayScale
  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .bottomTrailing) {
        ViewerView(model: model)
        if model.showHUD {
          TileHUD(store: model.tiles, renderer: model.renderer, iterations: model.iterations)
        }
        if model.atPrecisionLimit {
          Text("Maximum detail reached").font(.caption).padding(10)
            .background(.regularMaterial, in: Capsule()).frame(
              maxWidth: .infinity, maxHeight: .infinity, alignment: .top
            )
            .padding(.top, 16)
        }
        if let error = model.error {
          Text(error).padding().background(.regularMaterial).frame(
            maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .onAppear { model.resize(geometry.size, displayScale: displayScale) }
      .onChange(of: geometry.size) { _, size in model.resize(size, displayScale: displayScale) }
      .onChange(of: displayScale) { _, scale in model.resize(geometry.size, displayScale: scale) }
    }
    .onChange(of: scenePhase) { _, phase in model.setActive(phase == .active) }
    .onDisappear { model.setActive(false) }
    .onAppear { model.setActive(true) }
    .background(.black)
    .toolbar {
      Button {
        model.perform(.reset)
      } label: {
        Label("Reset", systemImage: "house")
      }
      Button {
        model.showSettings = true
      } label: {
        Label("Settings", systemImage: "slider.horizontal.3")
      }
      Button {
        model.showHelp = true
      } label: {
        Label("Controls", systemImage: "questionmark.circle")
      }
    }
    .sheet(isPresented: $model.showDeveloper) { DeveloperPanel(model: model) }
    .sheet(isPresented: $model.showBenchmark) {
      BenchmarkView(viewport: model.viewport, iterations: model.iterations)
    }
    .sheet(isPresented: $model.showSettings) { AppearanceView(model: model) }
    .sheet(isPresented: $model.showHelp) { HelpView() }
    .focusedSceneValue(\.explorer, model)
  }
}

struct TileHUD: View {
  @ObservedObject var store: TileStore
  let renderer: RendererID
  let iterations: Int
  var body: some View {
    VStack(alignment: .trailing) {
      Text("\(renderer.title) · \(iterations) iterations")
      Text(
        "\(store.statistics.tiles) tiles · \(store.statistics.bytes/1_048_576) MiB · \(store.statistics.pending) pending"
      )
      Text(
        "GPU frame \(store.statistics.frameMS,specifier:"%.2f") ms · max batch \(store.statistics.longestBatchMS,specifier:"%.2f") ms"
      )
      Text("\(store.statistics.cacheHits) hits · \(store.statistics.evictions) evictions")
      if let error = store.error { Text(error).foregroundStyle(.red) }
    }.font(.caption.monospacedDigit()).padding().background(
      .regularMaterial, in: RoundedRectangle(cornerRadius: 12)
    ).padding()
  }
}
