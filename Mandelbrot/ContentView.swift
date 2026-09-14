import SwiftUI

struct ContentView: View {
  @StateObject private var model = ExplorerModel()
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.displayScale) private var displayScale
  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      // The geometry and input surface share the full drawable area. Controls
      // remain siblings in the safe area, so their insets do not shift the camera.
      GeometryReader { geometry in
        ViewerView(model: model)
          .onAppear { model.resize(geometry.size, displayScale: displayScale) }
          .onChange(of: geometry.size) { _, size in model.resize(size, displayScale: displayScale) }
          .onChange(of: displayScale) { _, scale in model.resize(geometry.size, displayScale: scale)
          }
      }
      #if os(iOS)
        .ignoresSafeArea()
        .statusBarHidden()
      #endif
      TileFailureNotice(store: model.tiles)
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
    #if os(iOS)
      .overlay(alignment: .topTrailing) {
        HStack(spacing: 0) {
          viewerButton("Reset", icon: "house") { model.perform(.reset) }
          viewerButton("Settings", icon: "slider.horizontal.3") { model.showSettings = true }
          viewerButton("Controls", icon: "questionmark.circle") { model.showHelp = true }
        }
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .padding(12)
      }
    #endif
    .onChange(of: scenePhase) { _, phase in model.setActive(phase == .active) }
    .onDisappear { model.setActive(false) }
    .onAppear { model.setActive(true) }
    .background(.black)
    #if os(macOS)
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
    #endif
    .sheet(isPresented: $model.showDeveloper) { DeveloperPanel(model: model) }
    .sheet(isPresented: $model.showBenchmark) {
      BenchmarkView(viewport: model.viewport, iterations: model.iterations)
    }
    .sheet(isPresented: $model.showSettings) { AppearanceView(model: model) }
    .sheet(isPresented: $model.showHelp) { HelpView() }
    .focusedSceneValue(\.explorer, model)
  }

  #if os(iOS)
    private func viewerButton(_ title: String, icon: String, action: @escaping () -> Void)
      -> some View
    {
      Button(action: action) {
        Label(title, systemImage: icon)
          .labelStyle(.iconOnly)
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("viewer" + title)
    }
  #endif
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
      Text(
        "CPU draw \(store.statistics.preparationMS, specifier: "%.2f") ms · demand \(store.statistics.updateMS, specifier: "%.2f") ms · recent presentation \(store.statistics.presentationFPS, specifier: "%.0f") fps"
      )
      Text("\(store.statistics.cacheHits) hits · \(store.statistics.evictions) evictions")
      if let error = store.error {
        Text(error).foregroundStyle(.red)
        Button("Retry rendering") { store.retryFailedWork() }
      }
    }.font(.caption.monospacedDigit()).padding().background(
      .regularMaterial, in: RoundedRectangle(cornerRadius: 12)
    ).padding()
  }
}

struct TileFailureNotice: View {
  @ObservedObject var store: TileStore
  var body: some View {
    if let error = store.error {
      VStack {
        Text(error)
        Button("Retry rendering") { store.retryFailedWork() }
      }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding()
    }
  }
}
