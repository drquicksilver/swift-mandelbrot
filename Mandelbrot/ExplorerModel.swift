import Combine
import SwiftUI

@MainActor final class ExplorerModel: ObservableObject {
  let tiles = TileStore()
  let bookmarks: LocationStore
  private var tileObservation: AnyCancellable?
  init(bookmarks: LocationStore? = nil) {
    self.bookmarks = bookmarks ?? LocationStore()
    // Settled views report their escaped counts; each report may lower the
    // automatic limit.  Delivered after the publishing call returns.
    tileObservation = tiles.$statistics.receive(on: DispatchQueue.main).sink { [weak self] _ in
      MainActor.assumeIsolated {
        self?.observeDepth()
        self?.canAutoContrast = self?.tiles.allVisibleReady ?? false
      }
    }
    tiles.onContentChange = { [weak self] in self?.requestRedraw() }
    updateDepthColouring()
  }
  /// The single route to a frame.  Tile completion, a changed setting, a screen
  /// change and waking all come through here, and the canvas answers by both
  /// unpausing and marking itself dirty.  It is also the springs' clock:
  /// `advanceMotion` asks for its own next frame instead of waiting for some
  /// unrelated view to redraw.
  var onRedrawNeeded: (() -> Void)?
  private(set) var redrawRequests = 0
  func requestRedraw() {
    guard isActive else { return }
    redrawRequests &+= 1
    onRedrawNeeded?()
  }
  @Published var colouring = ColourSettings() {
    didSet {
      requestRedraw()
      requestJuliaRedraw()
    }
  }
  /// Contrast adjusts a scale-only logarithmic transfer. It never samples
  /// tiles, so it remains motionless whenever the camera is motionless.
  @Published var densityAdjustment: Float = 1 { didSet { updateDepthColouring() } }
  @Published var offsetAdjustment: Float = 0 { didSet { updateDepthColouring() } }
  @Published private(set) var colourSnapshotPinned = false
  @Published private(set) var canAutoContrast = false
  private var usesDepthColouring = true
  var isDepthColouring: Bool { usesDepthColouring }
  private var applyingLocation = false
  @Published var isActive = true
  func setActive(_ active: Bool) {
    isActive = active
    if active {
      updateDepth(force: true)
      requestRender()
    } else {
      stopMotion()
      interactionActive = false
      depthTask?.cancel()
      renderTask?.cancel()
      tiles.cancel()
    }
  }
  @Published var viewport = Viewport() {
    didSet {
      if viewport != oldValue {
        if usesDepthColouring { updateDepthColouring() }
        updateDepth()
        requestRender()
        // The crosshair is drawn from this view, and the panel shows it while
        // the two are swapped.
        if juliaSwapped { requestJuliaRedraw() }
      }
    }
  }
  private func updateDepthColouring() {
    guard usesDepthColouring, !applyingLocation else { return }
    colouring = DepthColouring.resolve(
      viewport: viewport, contrast: densityAdjustment, offsetAdjustment: offsetAdjustment,
      palette: colouring.palette, smooth: colouring.smooth)
  }
  /// Histogram fitting is deliberately one-shot: the result pins immediately.
  func autoContrastThisView() {
    guard
      let fit = AutomaticColourFit.resolve(
        histogram: tiles.visibleHistogram(), densityMultiplier: densityAdjustment,
        offsetAdjustment: offsetAdjustment)
    else { return }
    usesDepthColouring = false
    colourSnapshotPinned = true
    colouring.density = fit.density
    colouring.offset = fit.offset
    colouring.logarithmic = true
  }
  func useDepthColouring() {
    usesDepthColouring = true
    colourSnapshotPinned = false
    updateDepthColouring()
  }
  @Published private(set) var iterations = 200 {
    didSet {
      requestRender()
      requestJuliaRedraw()
    }
  }
  @Published var automaticIterations = true {
    didSet {
      ceiling = nil
      updateDepth(force: true)
    }
  }
  @Published var manualIterations = 200 { didSet { updateDepth(force: true) } }
  @Published var detailMultiplier = 1.0 { didSet { updateDepth(force: true) } }
  var interactionActive = false {
    didSet {
      if interactionActive {
        depthTask?.cancel()
      } else {
        updateDepth()
        observeDepth()
        // Springs run after the interaction, never during it.
        if isAnimating {
          motionActive = true
          requestRedraw()
        } else {
          recordHistory()
        }
      }
    }
  }
  private var depthTask: Task<Void, Never>?
  /// The observed ceiling on the automatic limit; see `IterationPolicy.observe`.
  private(set) var ceiling: IterationPolicy.Ceiling?
  func observeDepth() {
    guard automaticIterations, isActive, renderer.isGPU, !interactionActive, !motionActive,
      tiles.iterations == iterations, let maximum = tiles.visibleMaximumEscaped
    else { return }
    let next = IterationPolicy.observe(
      maximumEscaped: maximum, limit: iterations, logScale: viewport.logScale, ceiling: ceiling)
    guard next != ceiling else { return }
    ceiling = next
    updateDepth()
  }
  private func updateDepth(force: Bool = false) {
    depthTask?.cancel()
    let requested =
      automaticIterations
      ? IterationPolicy.target(
        logScale: viewport.logScale, multiplier: detailMultiplier, ceiling: ceiling)
      : max(1, min(IterationPolicy.maximum, manualIterations))
    let target = renderer.isGPU ? requested : min(65535, requested)
    if force || !automaticIterations {
      if iterations != target { iterations = target }
    } else if IterationPolicy.shouldRaise(current: iterations, target: target) {
      iterations = target
    } else if IterationPolicy.shouldLower(current: iterations, target: target) && !interactionActive
    {
      depthTask = Task { [weak self] in
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        guard let self, self.isActive, !self.motionActive, !self.interactionActive else { return }
        self.iterations = target
      }
    }
  }
  private func changeDetail(by factor: Double) {
    if automaticIterations {
      detailMultiplier = max(0.25, min(16, detailMultiplier * factor))
    } else {
      manualIterations = max(
        1,
        min(
          IterationPolicy.maximum,
          Int(min(Double(IterationPolicy.maximum), max(1, Double(manualIterations) * factor)))))
    }
  }
  @Published var rendererOverride: RendererID? {
    didSet {
      updateDepth(force: true)
      requestRender()
    }
  }
  @Published var image: CGImage?
  @Published var imageViewport = Viewport()
  @Published var duration = 0.0
  @Published var progress = 0.0
  @Published var error: String?
  @Published var showHelp = false
  @Published var showBenchmark = false
  @Published var showSettings = false
  @Published var showDeveloper = false
  @Published var showHUD = false
  @Published var showTileOverlay = false { didSet { requestRedraw() } }
  @Published var selection: CGRect?
  @Published var showPlaces = false
  /// The Julia companion: the point it follows, its own shallow view, and which
  /// of the two fills the main area.
  @Published var showJulia = false
  @Published var juliaSwapped = false
  @Published var juliaC = CGPoint(x: -0.8, y: 0.156) { didSet { requestJuliaRedraw() } }
  @Published var juliaViewport = Viewport(center: .zero, scale: 1) {
    didSet { requestJuliaRedraw() }
  }
  /// Whether c follows the pointer or finger by default.  A setting, remembered
  /// between launches.
  @Published var juliaFollows = ExplorerModel.defaultFollows {
    didSet { UserDefaults.standard.set(juliaFollows, forKey: ExplorerModel.followsKey) }
  }
  static let followsKey = "JuliaFollowsPointer"
  static var defaultFollows: Bool {
    UserDefaults.standard.object(forKey: followsKey) as? Bool ?? true
  }
  /// A pinned marker stays where it was put: it survives panning and zooming,
  /// and the pointer no longer moves it.
  @Published var juliaPinned = false
  /// The panel's own area, which its gestures measure against.
  var panelSize = CGSize(width: 220, height: 220)
  let julia = JuliaRenderer()
  let movies = MovieRenderer()
  @Published var showMovie = false
  /// Everything the panel draws from.  The panel's view is a SwiftUI value, and
  /// a value that never changes is a view SwiftUI never updates -- which is why
  /// the panel was never seen to redraw.  It now carries this.
  var juliaScene: JuliaScene {
    JuliaScene(
      c: juliaC, viewport: juliaViewport, iterations: iterations, colouring: colouring,
      swapped: juliaSwapped)
  }
  /// The panel's own redraw route, the companion's counterpart to
  /// `requestRedraw`: it does not share the main canvas's clock.
  var onJuliaRedrawNeeded: (() -> Void)?
  func requestJuliaRedraw() {
    guard isActive, showJulia else { return }
    onJuliaRedrawNeeded?()
  }
  /// The point c, on the Mandelbrot view, where the crosshair belongs -- or nil
  /// when there is no Mandelbrot view in the main area to put it on.
  var juliaMarker: CGPoint? {
    guard showJulia, !juliaSwapped else { return nil }
    return viewport.screen(for: juliaC, in: size)
  }
  /// How near the pointer has to be, in points, to take hold of the marker.
  static let markerGrabRadius = 22.0
  func isOnJuliaMarker(_ point: CGPoint) -> Bool {
    guard let marker = juliaMarker else { return false }
    return hypot(point.x - marker.x, point.y - marker.y) <= Self.markerGrabRadius
  }
  /// The panel follows the cursor or finger until the marker is pinned.
  func trackJulia(at point: CGPoint) {
    guard showJulia, juliaFollows, !juliaPinned, !juliaSwapped else { return }
    setJulia(at: point)
  }
  /// Moves c to a screen point on the Mandelbrot view, whether by following or
  /// by dragging the marker.
  func setJulia(at point: CGPoint) {
    let c = viewport.complex(at: point, in: size)
    guard c.x.isFinite, c.y.isFinite, abs(c.x) <= 4, abs(c.y) <= 4 else { return }
    juliaC = c
  }
  /// Dragging the marker pins it: it was put somewhere deliberately.
  func dragJulia(to point: CGPoint) {
    juliaPinned = true
    setJulia(at: point)
  }
  func toggleJuliaPin() {
    juliaPinned.toggle()
    requestJuliaRedraw()
  }
  func toggleJulia() {
    showJulia.toggle()
    if !showJulia { juliaSwapped = false }
    requestJuliaRedraw()
  }
  func swapJulia() {
    guard showJulia else { return }
    stopMotion()
    juliaSwapped.toggle()
    requestJuliaRedraw()
    requestRedraw()
  }
  /// The view the panel shows: the companion, or the Mandelbrot behind it when
  /// the two are swapped.  The panel's own gestures drive this, so it no longer
  /// takes a swap to zoom the companion.
  var panelViewport: Viewport {
    get { juliaSwapped ? viewport : juliaViewport }
    set {
      if juliaSwapped {
        viewport = newValue
      } else {
        juliaViewport = newValue
      }
    }
  }
  private var panelCentre: CGPoint {
    CGPoint(x: panelSize.width / 2, y: panelSize.height / 2)
  }
  func panPanel(_ delta: CGSize) {
    var next = panelViewport
    next.pan(by: delta, in: panelSize)
    panelViewport = next
  }
  func zoomPanel(_ factor: Double, at point: CGPoint? = nil) {
    var next = panelViewport
    // The companion stays shallow: float and double-float only.
    if !juliaSwapped, next.logScale + log2(max(1e-9, factor)) >= 26 { return }
    next.zoom(
      by: factor, at: point ?? panelCentre, in: panelSize,
      pixelWidth: panelSize.width * displayScale)
    panelViewport = next
  }
  func rotatePanel(_ delta: Double, at point: CGPoint? = nil) {
    guard delta.isFinite, delta != 0 else { return }
    var next = panelViewport
    next.rotate(by: delta, at: point ?? panelCentre, in: panelSize)
    panelViewport = next
  }
  func resetPanel() {
    panelViewport = juliaSwapped ? Viewport() : Viewport(center: .zero, scale: 1)
  }
  @Published var locationError: String?
  /// Back and forward history of settled views.  A view is recorded when it
  /// settles and differs from the last record by more than half a zoom level, a
  /// quarter of the screen, or two degrees.
  @Published private(set) var canGoBack = false
  @Published private(set) var canGoForward = false
  private var history: [Location] = []
  private var future: [Location] = []
  /// The last view put on the record, starting at the one the app opens with, so
  /// that leaving home can go back to it.
  private var recorded: Viewport? = Viewport()
  var location: Location {
    Location(
      viewport: viewport, iterations: automaticIterations ? nil : iterations, colouring: colouring,
      automaticColour: usesDepthColouring ? false : true,
      densityAdjustment: Double(densityAdjustment),
      offsetAdjustment: Double(offsetAdjustment))
  }
  private func differsFromRecord(_ view: Viewport) -> Bool {
    guard let recorded else { return true }
    if abs(view.logScale - recorded.logScale) > 0.5 { return true }
    if abs(Viewport.normalised(view.angle - recorded.angle)) > 2 * .pi / 180 { return true }
    let moved = recorded.screen(for: view.preciseCenter, in: size)
    return hypot(moved.x - size.width / 2, moved.y - size.height / 2) > size.width / 4
  }
  private func push(_ place: Location) {
    history.append(place)
    if history.count > 100 { history.removeFirst(history.count - 100) }
    future.removeAll()
  }
  /// The view being left, with the settings it was seen under.
  private func record(of view: Viewport) -> Location {
    Location(
      viewport: view, iterations: automaticIterations ? nil : iterations, colouring: colouring,
      automaticColour: usesDepthColouring ? false : true,
      densityAdjustment: Double(densityAdjustment),
      offsetAdjustment: Double(offsetAdjustment))
  }
  /// Records the view it is leaving, once the current one has come to rest and
  /// moved far enough to be a different place.
  func recordHistory() {
    guard differsFromRecord(viewport) else { return }
    if let recorded { push(record(of: recorded)) }
    recorded = viewport
    canGoBack = !history.isEmpty
    canGoForward = !future.isEmpty
  }
  func goBack() {
    guard let previous = history.popLast() else { return }
    let current = location
    apply(previous, record: false)
    future.append(current)
    canGoForward = true
  }
  func goForward() {
    guard let next = future.popLast() else { return }
    let current = location
    apply(next, record: false)
    history.append(current)
    canGoBack = true
  }
  /// Moves to a location: the view, its rotation, its palette and its detail.
  func apply(_ location: Location, record: Bool = true) {
    guard let view = try? location.viewport() else {
      locationError = "That location could not be opened."
      return
    }
    // Jumping somewhere always records where it came from, however near it is,
    // and records the view actually being left with the settings it was seen
    // under, not whichever view last settled onto the record.
    // `self`, because the parameter shadows the computed property.
    if record, viewport != view { push(self.location) }
    stopMotion()
    applyingLocation = true
    colouring = location.colouring
    // Missing is a historic fixed-colour URL. `depth` is the new deterministic
    // mapping and `auto` is the explicit one-shot histogram override.
    usesDepthColouring = location.automaticColour == false
    densityAdjustment = Float(location.densityAdjustment ?? 1)
    offsetAdjustment = Float(location.offsetAdjustment ?? 0)
    colourSnapshotPinned = location.automaticColour == true
    if let limit = location.iterations {
      automaticIterations = false
      manualIterations = limit
    } else {
      automaticIterations = true
    }
    viewport = view
    applyingLocation = false
    updateDepthColouring()
    recorded = view
    canGoBack = !history.isEmpty
    canGoForward = !future.isEmpty
    locationError = nil
  }
  func open(_ url: URL) {
    do {
      apply(try Location(url: url))
    } catch {
      locationError = String(describing: error)
    }
  }
  func bookmarkCurrentView(named name: String? = nil) {
    var place = location
    place.name =
      name?.isEmpty == false
      ? name! : "\(viewport.scaleDescription.prefix(12))× view"
    bookmarks.add(place)
  }
  var motion = Motion()
  @Published private(set) var motionActive = false
  var motionAnchor: CGPoint?
  private var lastMotionTime: Double?
  var zoomDirection = 0
  func stopMotion() {
    motion.stop()
    rotationTarget = nil
    motionActive = false
    lastMotionTime = nil
    zoomDirection = 0
  }
  func fling(
    pan: CGPoint = .zero, zoom: Double = 0, rotation: Double = 0, anchor: CGPoint? = nil
  ) {
    motion.velocity = SIMD2(max(-4000, min(4000, pan.x)), max(-4000, min(4000, pan.y)))
    motion.zoomVelocity = max(-4, min(4, zoom))
    // A snap, just decided by endTwist, owns the angle: a fling must not undo it.
    motion.rotationVelocity = rotationTarget == nil ? max(-12, min(12, rotation)) : 0
    motionAnchor = anchor
    lastMotionTime = ProcessInfo.processInfo.systemUptime
    motionActive = motion.active
    if motionActive { requestRedraw() }
  }
  /// Rotation, gentle bounds and the compass all animate here, so the display
  /// keeps drawing while any of them is still moving.
  var isAnimating: Bool {
    // The bounds spring belongs to the Mandelbrot view.  While the companion
    // holds the main area nothing pulls it back, so it must not keep the display
    // awake either.
    motion.active || rotationTarget != nil
      || (!interactionActive && !juliaSwapped && boundsNeeded)
  }
  private(set) var rotationTarget: Double?
  private var twist = 0.0
  var centreOfView: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }
  /// The view the gestures drive: the companion, while it holds the main area.
  /// Pan and zoom have always followed the swap; rotation follows it too, so a
  /// twist turns the picture the user is actually looking at.
  var mainViewport: Viewport {
    get { juliaSwapped ? juliaViewport : viewport }
    set {
      if juliaSwapped {
        juliaViewport = newValue
      } else {
        viewport = newValue
      }
    }
  }
  func rotate(_ delta: Double, at point: CGPoint? = nil) {
    guard delta.isFinite, delta != 0 else { return }
    rotationTarget = nil
    var next = mainViewport
    next.rotate(by: delta, at: point ?? centreOfView, in: size)
    mainViewport = next
  }
  /// A pinch ignores its first ten degrees of twist, so zooming does not leave
  /// the view tilted; past that the gesture rotates one to one.  Returns the
  /// rotation it actually applied, which is what may be flung on release: the
  /// raw finger movement includes the part deliberately ignored.
  @discardableResult func applyTwist(_ delta: Double, at point: CGPoint) -> Double {
    guard delta.isFinite, delta != 0 else { return 0 }
    let threshold = 10 * Double.pi / 180
    twist += delta
    guard abs(twist) > threshold else { return 0 }
    let effective = twist > 0 ? twist - threshold : twist + threshold
    twist = twist > 0 ? threshold : -threshold
    rotate(effective, at: point)
    return effective
  }
  /// Ends a twist and snaps to a right angle when within three degrees.
  func endTwist(velocity: Double = 0, at point: CGPoint? = nil) {
    twist = 0
    let quarter = Double.pi / 2
    let angle = mainViewport.angle
    let nearest = (angle / quarter).rounded() * quarter
    guard abs(Viewport.normalised(angle - nearest)) <= 3 * Double.pi / 180 else { return }
    guard angle != Viewport.normalised(nearest) else { return }
    rotationTarget = Viewport.normalised(nearest)
    motion.rotationVelocity = 0
    requestRedraw()
    hapticTick()
  }
  /// Animates back to upright, for the compass button.
  func resetRotation() {
    guard mainViewport.angle != 0 else { return }
    motion.rotationVelocity = 0
    rotationTarget = 0
    motionActive = true
    requestRedraw()
  }
  private func hapticTick() {
    #if os(iOS)
      guard UIDevice.current.userInterfaceIdiom == .phone else { return }
      UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
    #endif
  }
  /// Gentle bounds: zooming out past the whole set, or panning far into empty
  /// space, springs back until part of the set is in view.  Both springs use the
  /// same analytic decay as inertia, so they are frame-rate independent.
  private func applyBounds(_ view: inout Viewport, seconds: Double) -> Bool {
    let rate = 9.0
    var sprung = false
    let resting = Viewport.restingLogScale(size: size)
    if view.logScale < resting - 1e-9 {
      let next = Motion.approach(from: view.logScale, to: resting, rate: rate, seconds: seconds)
      view.zoom(
        by: pow(2, next - view.logScale), at: centreOfView, in: size, pixelWidth: pixelWidth)
      motion.zoomVelocity = 0
      sprung = true
    }
    let target = view.boundedCenter(size: size)
    let offset = hypot(target.x - view.center.x, target.y - view.center.y)
    if offset > view.span * 1e-6 {
      let fraction = 1 - exp(-rate * min(seconds, 0.05))
      let from = view.screen(for: target, in: size)
      view.pan(
        by: CGSize(
          width: (centreOfView.x - from.x) * fraction, height: (centreOfView.y - from.y) * fraction),
        in: size)
      motion.velocity = .zero
      sprung = true
    }
    return sprung
  }
  /// Eases a view towards the snap or compass target, and clears it on arrival.
  private func approachRotationTarget(_ view: inout Viewport, seconds: Double) {
    guard let target = rotationTarget else { return }
    let remaining = Viewport.normalised(target - view.angle)
    if abs(remaining) < 1e-4 {
      view.rotate(by: remaining, at: centreOfView, in: size)
      rotationTarget = nil
    } else {
      view.rotate(
        by: Motion.approach(from: 0, to: remaining, rate: 12, seconds: seconds), at: centreOfView,
        in: size)
    }
  }
  func advanceMotion(now: Double) {
    guard isActive, isAnimating else {
      lastMotionTime = nil
      return
    }
    let dt = now - (lastMotionTime ?? now)
    lastMotionTime = now
    zoomDirection = motion.zoomVelocity > 0 ? 1 : (motion.zoomVelocity < 0 ? -1 : 0)
    let delta = motion.step(seconds: dt)
    if juliaSwapped {
      // Flings in the companion pan, zoom and rotate its own shallow view.
      var companion = juliaViewport
      companion.pan(by: delta.pan, in: size)
      let anchor = motionAnchor ?? centreOfView
      if delta.rotation != 0 { companion.rotate(by: delta.rotation, at: anchor, in: size) }
      let wanted = companion.logScale + log2(max(1e-9, delta.zoom))
      if wanted < 26 {
        companion.zoom(by: delta.zoom, at: anchor, in: size, pixelWidth: pixelWidth)
      }
      approachRotationTarget(&companion, seconds: dt)
      juliaViewport = companion
      if motionActive != isAnimating { motionActive = isAnimating }
      if isAnimating { requestRedraw() }
      return
    }
    var next = viewport
    next.pan(by: delta.pan, in: size)
    let anchor = motionAnchor ?? centreOfView
    if delta.rotation != 0 { next.rotate(by: delta.rotation, at: anchor, in: size) }
    atPrecisionLimit = next.zoom(by: delta.zoom, at: anchor, in: size, pixelWidth: pixelWidth)
    if atPrecisionLimit && motion.zoomVelocity > 0 {
      // Bounce off the precision limit rather than stopping dead.
      motion.zoomVelocity = -min(1.5, motion.zoomVelocity / 3)
    }
    approachRotationTarget(&next, seconds: dt)
    if !interactionActive { _ = applyBounds(&next, seconds: dt) }
    viewport = next
    if motionActive != isAnimating {
      motionActive = isAnimating
      if !motionActive {
        observeDepth()
        recordHistory()
      }
    }
    if isAnimating { requestRedraw() }
  }
  @Published var atPrecisionLimit = false
  /// Whether the resting view would spring: used to wake the display when an
  /// interaction ends outside the gentle bounds.
  var boundsNeeded: Bool {
    if viewport.logScale < Viewport.restingLogScale(size: size) - 1e-9 { return true }
    let bounded = viewport.boundedCenter(size: size)
    return hypot(bounded.x - viewport.center.x, bounded.y - viewport.center.y)
      > viewport.span * 1e-6
  }
  var size = CGSize(width: 900, height: 600)
  var displayScale = 1.0
  private var renderTask: Task<Void, Never>?
  var pixelWidth: Double { size.width * displayScale }
  var renderer: RendererID {
    PrecisionPolicy.renderer(
      logScale: viewport.logScale, pixelWidth: pixelWidth, center: viewport.center,
      override: rendererOverride)
  }

  func resize(_ size: CGSize, displayScale: Double) {
    guard size.width > 0, size.height > 0 else { return }
    self.size = size
    self.displayScale = displayScale
    viewport.zoom(
      by: 1, at: CGPoint(x: size.width / 2, y: size.height / 2), in: size, pixelWidth: pixelWidth)
    requestRender()
  }
  func pan(_ delta: CGSize) {
    zoomDirection = 0
    // While the companion holds the main area, gestures drive its view.
    if juliaSwapped {
      juliaViewport.pan(by: delta, in: size)
      return
    }
    viewport.pan(by: delta, in: size)
  }
  func zoom(_ factor: Double, at point: CGPoint? = nil) {
    zoomDirection = factor > 1 ? 1 : (factor < 1 ? -1 : 0)
    if juliaSwapped {
      // The companion stays shallow: float and double-float only.
      let wanted = juliaViewport.logScale + log2(max(1e-9, factor))
      guard wanted < 26 else { return }
      juliaViewport.zoom(
        by: factor, at: point ?? centreOfView, in: size, pixelWidth: pixelWidth)
      return
    }
    atPrecisionLimit = viewport.zoom(
      by: factor, at: point ?? CGPoint(x: size.width / 2, y: size.height / 2),
      in: size, pixelWidth: pixelWidth)
  }
  func perform(_ command: ExplorerCommand) {
    stopMotion()
    // Keyboard navigation settles the instant it runs: nothing else will call
    // recordHistory for it, as an interaction or a spring would.
    defer {
      switch command {
      // resetRotation animates, so the spring's own settle records it.
      case .reset, .zoomIn, .zoomOut, .left, .right, .up, .down, .rotateLeft, .rotateRight:
        recordHistory()
      default: break
      }
    }
    switch command {
    case .reset:
      viewport = Viewport()
      atPrecisionLimit = false
    case .zoomIn: zoom(2)
    case .zoomOut: zoom(0.5)
    case .left: pan(CGSize(width: 80, height: 0))
    case .right: pan(CGSize(width: -80, height: 0))
    case .up: pan(CGSize(width: 0, height: 80))
    case .down: pan(CGSize(width: 0, height: -80))
    case .increaseIterations: changeDetail(by: 2)
    case .decreaseIterations: changeDetail(by: 0.5)
    case .rotateLeft: rotate(-.pi / 12)
    case .rotateRight: rotate(.pi / 12)
    case .resetRotation: resetRotation()
    case .back: goBack()
    case .forward: goForward()
    case .places: showPlaces.toggle()
    case .bookmark: bookmarkCurrentView()
    case .julia: toggleJulia()
    case .swapJulia: swapJulia()
    case .movie: showMovie = true
    case .benchmark: showBenchmark.toggle()
    case .help: showHelp.toggle()
    }
  }
  func requestRender() {
    renderTask?.cancel()
    guard isActive else { return }
    requestRedraw()
    if renderer.isGPU {
      error = GPUContext.shared == nil ? "Metal is unavailable." : nil
      return
    }
    tiles.cancel()
    let view = viewport
    let renderer = renderer
    let iterations = min(65535, iterations)
    let width = max(1, Int(size.width * displayScale))
    let height = max(1, Int(size.height * displayScale))
    renderTask = Task { [weak self] in
      let start = ContinuousClock.now
      for block in [32, 8, 2, 1] {
        guard !Task.isCancelled else { return }
        let image = await RenderWorker.shared.renderImage(
          variant: renderer.rawValue,
          width: width,
          height: height,
          center: view.center, scale: view.scale, blockSize: block,
          configuration: MandelbrotConfiguration(maxIterations: iterations))
        guard !Task.isCancelled, let self else { return }
        if let image {
          self.image = image
          self.imageViewport = view
          self.error = nil
        } else {
          self.error = "The renderer is unavailable."
        }
        self.progress = block == 1 ? 1 : 0.5
      }
      let elapsed = start.duration(to: .now).components
      self?.duration = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
  }
}
