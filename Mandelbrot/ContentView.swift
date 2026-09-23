import SwiftUI

struct ContentView: View {
  @StateObject private var model = ExplorerModel()
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.displayScale) private var displayScale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  #if os(macOS)
    @Environment(\.appearsActive) private var appearsActive
  #endif
  /// The companion's share of a wide window, which its divider drags.
  @AppStorage("CompanionFraction") private var companionFraction = 0.28
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
        let panel =
          sideBySide
          ? CGSize(
            width: max(220, geometry.size.width * companionFraction), height: geometry.size.height)
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
            .onChange(of: companionFraction) { _, _ in
              model.resize(viewerSize(geometry.size, panel), displayScale: displayScale)
            }
            .onChange(of: displayScale) { _, scale in
              model.resize(viewerSize(geometry.size, panel), displayScale: scale)
            }
          if model.showJulia && sideBySide {
            CompanionDivider(fraction: $companionFraction, width: geometry.size.width)
            CompanionPanel(model: model).frame(width: panel.width)
          }
        }
        .coordinateSpace(.named(CompanionDivider.space))
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
        Text("Deepest zoom reached").font(.caption).padding(10)
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
          viewerButton(.reset) { model.perform(.reset) }
          if model.canGoBack {
            viewerButton(.back) { model.perform(.back) }
          }
          viewerButton(.places) { model.showPlaces = true }
          viewerButton(.julia) { model.toggleJulia() }
          viewerButton(.movie) { model.showMovie = true }
          viewerButton(.settings) { model.showSettings = true }
          viewerButton(.help) { model.showHelp = true }
        }
        .padding(4)
        // Symbols grow with Dynamic Type only so far: at the accessibility
        // sizes seven of them overflowed the capsule and each other.  The
        // buttons keep their labels, which VoiceOver and Large Content Viewer
        // read at any size.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        // Dark material whatever the system appearance: over a pale band of
        // the set a light capsule left its glyphs grey on cream.  A tint
        // under it keeps a floor on the contrast however bright the image.
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color.black.opacity(0.35), in: Capsule())
        .environment(\.colorScheme, .dark)
        .padding(12)
      }
    #endif
    .onOpenURL { url in model.open(url) }
    .onChange(of: scenePhase) { _, phase in model.setActive(phase == .active) }
    .onDisappear { model.setActive(false) }
    .onAppear {
      model.reduceMotion = reduceMotion
      model.restoreLastLocation()
      model.setActive(true)
    }
    .onChange(of: reduceMotion) { _, reduce in model.reduceMotion = reduce }
    .background(.black)
    #if os(macOS)
      .toolbar {
        toolbarButton(.reset) { model.perform(.reset) }
        // Always present, so the cluster does not reflow as the view turns.
        Button {
          model.resetRotation()
        } label: {
          Label(ToolbarAction.upright.title, systemImage: ToolbarAction.upright.icon)
          .rotationEffect(.radians(-model.mainViewport.angle))
        }
        .help(ToolbarAction.upright.explanation)
        .disabled(!model.canPerform(.resetRotation))
        toolbarButton(.back) { model.perform(.back) }
        .disabled(!model.canGoBack)
        toolbarButton(.forward) { model.perform(.forward) }
        .disabled(!model.canGoForward)
        toolbarButton(.places) { model.showPlaces = true }
        toolbarButton(.bookmark) { model.bookmarkCurrentView() }
        toolbarButton(.julia) { model.toggleJulia() }
        toolbarButton(.movie) { model.showMovie = true }
        ShareLink(item: model.location.url) {
          Label(ToolbarAction.share.title, systemImage: ToolbarAction.share.icon)
        }
        .help(ToolbarAction.share.explanation)
        toolbarButton(.settings) { model.showSettings = true }
        toolbarButton(.help) { model.showHelp = true }
      }
    #endif
    #if os(macOS)
      // Where you are, always: the half of "the app never says" that a Mac
      // title bar already has room for.
      .navigationSubtitle(model.mainViewport.zoomDescription)
    #endif
    #if os(macOS)
      .onChange(of: appearsActive, initial: true) { _, active in
        if active { ExplorerRegistry.shared.current = model }
      }
    #else
      .sheet(isPresented: $model.showDeveloper) { DeveloperPanel(model: model) }
    #endif
    .sheet(isPresented: $model.showBenchmark) {
      BenchmarkView(viewport: model.viewport, iterations: model.iterations)
    }
    .sheet(isPresented: $model.showPlaces) { PlacesView(model: model) }
    .sheet(isPresented: $model.showMovie) {
      // Each platform has its own shape: a dialog on the Mac, a grouped form
      // where a sheet fills a phone.
      #if os(macOS)
        MovieSheetMac(model: model)
          .presentationSizing(.form.fitted(horizontal: true, vertical: true))
      #else
        MovieView(model: model)
      #endif
    }
    .sheet(isPresented: $model.showSettings) { AppearanceView(model: model) }
    .sheet(isPresented: $model.showHelp) { HelpView() }
    .focusedSceneObject(model)
  }

  #if os(macOS)
    /// Every toolbar button, with the tooltip that explains it -- the same
    /// sentence the help shows beside the same icon.
    private func toolbarButton(_ action: ToolbarAction, perform: @escaping () -> Void)
      -> some View
    {
      Button(action: perform) {
        Label(action.title, systemImage: action.icon)
      }
      .help(action.explanation)
      .accessibilityIdentifier("viewer" + action.title)
    }
  #endif

  private func viewerSize(_ total: CGSize, _ panel: CGSize) -> CGSize {
    guard model.showJulia && sideBySide else { return total }
    return CGSize(width: max(1, total.width - panel.width), height: total.height)
  }

  #if os(iOS)
    private func viewerButton(_ action: ToolbarAction, perform: @escaping () -> Void)
      -> some View
    {
      Button(action: perform) {
        Label(action.title, systemImage: action.icon)
          .labelStyle(.iconOnly)
          .frame(minWidth: 44, minHeight: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityShowsLargeContentViewer {
        Label(action.title, systemImage: action.icon)
      }
      .help(action.explanation)
      .accessibilityHint(action.explanation)
      .accessibilityIdentifier("viewer" + action.title)
    }
  #endif
}

/// The line between the view and the companion, which drags to share the
/// window differently.  Its target is wider than the line it draws.
struct CompanionDivider: View {
  static let space = "companionSplit"
  static let range = 0.15...0.6
  @Binding var fraction: Double
  let width: CGFloat
  var body: some View {
    Divider()
      .overlay {
        Color.clear
          .frame(width: 9)
          .contentShape(Rectangle())
          .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
              .onChanged { drag in
                let share = 1 - drag.location.x / max(1, width)
                fraction = min(Self.range.upperBound, max(Self.range.lowerBound, share))
              }
          )
          #if os(macOS)
            .onHover { inside in
              if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
          #endif
      }
      .zIndex(1)
      .accessibilityElement()
      .accessibilityLabel(Text("Companion width"))
      .accessibilityValue(Text(fraction.formatted(.percent.precision(.fractionLength(0)))))
      .accessibilityAdjustableAction { direction in
        let step = direction == .increment ? 0.05 : -0.05
        fraction = min(Self.range.upperBound, max(Self.range.lowerBound, fraction + step))
      }
  }
}

/// While the view is rotated, a compass button animates it back to upright.
struct RotationCompass: View {
  @ObservedObject var model: ExplorerModel
  var body: some View {
    if abs(model.mainViewport.angle) > 0.001 {
      let degrees = -model.mainViewport.angle * 180 / .pi
      Button {
        model.resetRotation()
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "location.north.line")
            .rotationEffect(.radians(-model.mainViewport.angle))
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
        Button("Try Again") { store.retryFailedWork() }
      }
    }.font(.caption.monospacedDigit()).padding().background(
      .regularMaterial, in: RoundedRectangle(cornerRadius: 12)
    ).padding()
  }
}

struct TileFailureNotice: View {
  @ObservedObject var store: TileStore
  var body: some View {
    // The store's error is for the performance HUD; this is for everyone.
    if store.error != nil {
      VStack {
        Text("Part of this view couldn’t be drawn.")
        Button("Try Again") { store.retryFailedWork() }
      }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding()
    }
  }
}
