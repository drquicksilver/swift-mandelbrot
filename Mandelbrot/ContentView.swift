import SwiftUI

struct ContentView: View {
  @StateObject private var model = ExplorerModel()
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.displayScale) private var displayScale
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var sideBySide: Bool { sizeClass != .compact }
  #else
    private var sideBySide: Bool { true }
  #endif
  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      // The geometry and input surface share the full drawable area. Controls
      // remain siblings in the safe area, so their insets do not shift the camera.
      GeometryReader { geometry in
        // A wide screen puts the companion beside the view; a phone insets it in
        // a corner.  Either way the main area keeps the full input surface.
        let panel = sideBySide
          ? CGSize(width: max(220, geometry.size.width * 0.28), height: geometry.size.height)
          : CGSize(
            width: min(geometry.size.width * 0.42, 220),
            height: min(geometry.size.width * 0.42, 220))
        HStack(spacing: 0) {
          ViewerView(model: model)
            .onAppear { model.resize(viewerSize(geometry.size, panel), displayScale: displayScale) }
            .onChange(of: geometry.size) { _, size in
              model.resize(viewerSize(size, panel), displayScale: displayScale)
            }
            .onChange(of: model.showJulia) { _, _ in
              model.resize(viewerSize(geometry.size, panel), displayScale: displayScale)
            }
            .onChange(of: displayScale) { _, scale in
              model.resize(viewerSize(geometry.size, panel), displayScale: scale)
            }
          if model.showJulia && sideBySide {
            Divider()
            CompanionPanel(model: model).frame(width: panel.width)
          }
        }
        .overlay(alignment: .bottomTrailing) {
          if model.showJulia && !sideBySide {
            CompanionPanel(model: model)
              .frame(width: panel.width, height: panel.height)
              .clipShape(RoundedRectangle(cornerRadius: 12))
              .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.25)))
              .padding(12)
          }
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
      RotationCompass(model: model)
      if model.atPrecisionLimit {
        Text("Maximum detail reached").font(.caption).padding(10)
          .background(.regularMaterial, in: Capsule()).frame(
            maxWidth: .infinity, maxHeight: .infinity, alignment: .top
          )
          .padding(.top, 16)
      }
      if let error = model.locationError {
        Text(error).font(.caption).padding(10)
          .background(.regularMaterial, in: Capsule())
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .padding(.top, 56)
          .onTapGesture { model.locationError = nil }
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
          if model.canGoBack {
            viewerButton("Back", icon: "chevron.backward") { model.perform(.back) }
          }
          viewerButton("Places", icon: "bookmark") { model.showPlaces = true }
          viewerButton("Julia", icon: "circle.lefthalf.filled") { model.toggleJulia() }
          viewerButton("Settings", icon: "slider.horizontal.3") { model.showSettings = true }
          viewerButton("Controls", icon: "questionmark.circle") { model.showHelp = true }
        }
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .padding(12)
      }
    #endif
    .onOpenURL { url in model.open(url) }
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
        if abs(model.viewport.angle) > 0.001 {
          Button {
            model.resetRotation()
          } label: {
            Label("Upright", systemImage: "location.north.line")
              .rotationEffect(.radians(-model.viewport.angle))
          }
        }
        Button {
          model.perform(.back)
        } label: {
          Label("Back", systemImage: "chevron.backward")
        }
        .disabled(!model.canGoBack)
        Button {
          model.perform(.forward)
        } label: {
          Label("Forward", systemImage: "chevron.forward")
        }
        .disabled(!model.canGoForward)
        Button {
          model.showPlaces = true
        } label: {
          Label("Places", systemImage: "bookmark")
        }
        Button {
          model.toggleJulia()
        } label: {
          Label("Julia Companion", systemImage: "circle.lefthalf.filled")
        }
        ShareLink(item: model.location.url) {
          Label("Share", systemImage: "square.and.arrow.up")
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
    .sheet(isPresented: $model.showPlaces) { PlacesView(model: model) }
    .sheet(isPresented: $model.showSettings) { AppearanceView(model: model) }
    .sheet(isPresented: $model.showHelp) { HelpView() }
    .focusedSceneValue(\.explorer, model)
  }

  private func viewerSize(_ total: CGSize, _ panel: CGSize) -> CGSize {
    guard model.showJulia && sideBySide else { return total }
    return CGSize(width: max(1, total.width - panel.width), height: total.height)
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

/// While the view is rotated, a compass button animates it back to upright.
struct RotationCompass: View {
  @ObservedObject var model: ExplorerModel
  var body: some View {
    if abs(model.viewport.angle) > 0.001 {
      let degrees = -model.viewport.angle * 180 / .pi
      Button {
        model.resetRotation()
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "location.north.line")
            .rotationEffect(.radians(-model.viewport.angle))
          Text("\(degrees, specifier: "%.0f")°").font(.caption.monospacedDigit())
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .background(.regularMaterial, in: Capsule())
      .accessibilityIdentifier("viewerUpright")
      .accessibilityLabel("Rotate upright")
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
      .padding(20)
    }
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
