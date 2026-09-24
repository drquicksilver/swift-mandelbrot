import Combine
import SwiftUI

@MainActor final class ExplorerModel: ObservableObject {
  let tiles = TileStore()
  let bookmarks: LocationStore
  private var tileObservation: AnyCancellable?
  private var bookmarkObservation: AnyCancellable?
  /// Where the last location is remembered; tests pass their own.
  let defaults: UserDefaults
  init(bookmarks: LocationStore? = nil, defaults: UserDefaults = .standard) {
    self.bookmarks = bookmarks ?? LocationStore()
    self.defaults = defaults
    // Settled views report their escaped counts; each report may lower the
    // automatic limit.  Delivered after the publishing call returns.
    tileObservation = tiles.$statistics.receive(on: DispatchQueue.main).sink { [weak self] _ in
      MainActor.assumeIsolated {
        self?.observeDepth()
        self?.canAutoContrast = self?.tiles.allVisibleReady ?? false
      }
    }
    tiles.onContentChange = { [weak self] in self?.requestRedraw() }
    // Places may delete or add a bookmark behind the model's back.  The
    // publisher delivers the list before the store holds it.
    bookmarkObservation = self.bookmarks.$bookmarks.sink { [weak self] list in
      MainActor.assumeIsolated { self?.refreshBookmarked(list) }
    }
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
    guard automaticIterations, isActive, !interactionActive, !motionActive,
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
    let target =
      automaticIterations
      ? IterationPolicy.target(
        logScale: viewport.logScale, multiplier: detailMultiplier, ceiling: ceiling)
      : max(1, min(IterationPolicy.maximum, manualIterations))
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
  /// A developer override of the automatic precision ladder: one of the GPU
  /// renderers, which deep views still overrule with perturbation.
  @Published var rendererOverride: RendererID? { didSet { requestRender() } }
  @Published var error: String?
  @Published var showHelp = false
  @Published var showBenchmark = false
  @Published var showSettings = false
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
  /// The crosshair's point as a person reads it: −0.7436 + 0.1318i.
  var juliaPoint: String {
    PointFormat.string(
      x: Double(juliaC.x), y: Double(juliaC.y),
      style: .number.precision(.fractionLength(4)))
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
    // A phone has no pointer to hover, so without this the companion opened
    // on a default c nowhere near the view, and no crosshair to explain it.
    if showJulia && !juliaPinned { centreJulia() }
    requestJuliaRedraw()
  }
  /// Puts c at the middle of the Mandelbrot view.
  func centreJulia() {
    setJulia(at: CGPoint(x: size.width / 2, y: size.height / 2))
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
    rememberLocation()
    refreshBookmarked()
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
      locationError = ExplorerModel.unopenableLink
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
    rememberLocation()
    refreshBookmarked()
  }
  /// Set by the window: only a view someone is looking at is worth coming
  /// back to, never a diagnostic's or the command line's.
  var remembersLocation = false
  static let lastLocationKey = "LastLocation"
  private func rememberLocation() {
    guard remembersLocation, !applyingLocation else { return }
    defaults.set(location.url.absoluteString, forKey: Self.lastLocationKey)
  }
  /// Opens where the last session left off, as a place rather than a move.
  func restoreLastLocation() {
    remembersLocation = true
    guard let text = defaults.string(forKey: Self.lastLocationKey),
      let url = URL(string: text), let place = try? Location(url: url)
    else { return }
    apply(place, record: false)
  }
  /// A move to a place in progress, stepped by the motion clock like every
  /// other animation, so it keeps the display's pace and a gesture stops it.
  struct Travel {
    let journey: Journey
    let place: Location
    let origin: Location
    let seconds: Double
    var start: Double?
  }
  private(set) var travelling: Travel?
  /// Goes to a place the way a movie would, as one short continuous move,
  /// so a jump shows where the place is rather than cutting to it.  Under
  /// Reduce Motion, or when there is no route, it is the plain cut.  Any
  /// gesture stops it where it is.
  func travel(to place: Location) {
    stopMotion()
    let aspect = Double(size.width / max(1, size.height))
    guard !reduceMotion, isActive,
      let journey = try? Journey.planned(start: location, end: place, aspectRatio: aspect)
    else {
      apply(place)
      return
    }
    // Long enough to follow, short enough not to be a wait: a deep descent
    // is compressed, a near neighbour is not stretched.
    let seconds = min(1.6, max(0.6, journey.minimumDuration * 0.3))
    travelling = Travel(journey: journey, place: place, origin: location, seconds: seconds)
    motionActive = true
    requestRedraw()
  }
  /// One step of a travel; true while it has further to go.
  private func advanceTravel(now: Double) -> Bool {
    guard var travel = travelling else { return false }
    let start = travel.start ?? now
    travel.start = start
    travelling = travel
    let t = min(1, (now - start) / travel.seconds)
    if let view = try? travel.journey.viewport(
      at: t, duration: travel.journey.requestedDuration)
    {
      // The direction steers the tile store's prefetch, as a fling's does.
      zoomDirection =
        view.logScale > viewport.logScale ? 1 : (view.logScale < viewport.logScale ? -1 : 0)
      viewport = view
    }
    guard t >= 1 else { return true }
    travelling = nil
    // The view has already arrived, so apply's own record would see no
    // move; the place left is recorded here instead.
    push(travel.origin)
    apply(travel.place, record: false)
    return false
  }
  func open(_ url: URL) {
    do {
      apply(try Location(url: url))
    } catch {
      // The parser's reason is for the code; a person needs to know the link
      // did nothing, and that the view they had is still there.
      locationError = ExplorerModel.unopenableLink
    }
  }
  static let unopenableLink = String(
    localized: "That link isn’t a complete Mandelbrot place, so it couldn’t be opened.")
  /// Whether this view is the place: the same zoom, and a centre too close to
  /// see the difference.  Palette and detail do not count; it is where you
  /// are that Places marks.
  func isShowing(_ place: Location) -> Bool {
    guard let view = try? place.viewport(), abs(view.logScale - viewport.logScale) < 0.05
    else { return false }
    let there = viewport.screen(for: view.preciseCenter, in: size)
    let off = hypot(there.x - size.width / 2, there.y - size.height / 2)
    return off <= max(1, max(size.width, size.height) * 0.01)
  }
  /// Bookmarks this view, unless it is bookmarked already: a second click
  /// says so instead of making a copy.  A typed name always makes a new one.
  func bookmarkCurrentView(named name: String? = nil) {
    let typed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if typed.isEmpty, let existing = bookmarks.bookmarks.first(where: isShowing) {
      announce(existing, isNew: false)
      return
    }
    var place = location
    place.name = typed.isEmpty ? place.suggestedName : typed
    bookmarks.add(place)
    announce(place, isNew: true)
  }
  /// Whether this view is one of the bookmarks.  Kept rather than computed,
  /// since the toolbar is drawn every frame of a gesture; it is brought up
  /// to date when a view settles and whenever the bookmarks change.
  @Published private(set) var isBookmarkedHere = false
  private func refreshBookmarked(_ list: [Location]? = nil) {
    let here = (list ?? bookmarks.bookmarks).contains(where: isShowing)
    if here != isBookmarkedHere { isBookmarkedHere = here }
  }
  /// The acknowledgement of the last bookmark, for the window to show.
  /// Behind a sheet there is nobody to show it to: Places shows the new
  /// bookmark itself.
  @Published var bookmarkNotice: BookmarkNotice?
  private func announce(_ place: Location, isNew: Bool) {
    guard !isPresentingSheet else { return }
    bookmarkNotice = BookmarkNotice(place: place, isNew: isNew)
  }
  /// Takes back a bookmark just made.
  func undoBookmark(_ place: Location) {
    bookmarks.remove(place)
    if bookmarkNotice?.place.id == place.id { bookmarkNotice = nil }
  }
  /// The bookmark being named from the notice, while its field is up.
  @Published var namingBookmark: Location?
  /// A still of the canvas as it is on screen, from the tiles already drawn.
  func snapshot(maximumWidth: Int = 1600) async -> CGImage? {
    guard size.width > 0, size.height > 0, let gpu = GPUContext.shared else { return nil }
    let scale = min(Double(displayScale), Double(maximumWidth) / Double(size.width))
    let width = max(1, Int((Double(size.width) * scale).rounded()))
    let height = max(1, Int((Double(size.height) * scale).rounded()))
    guard
      let texture = try? await TileCompositor.snapshot(
        store: tiles, viewport: viewport, width: width, height: height,
        now: ProcessInfo.processInfo.systemUptime + TilePresentation.fadeDuration)
    else { return nil }
    return try? await gpu.image(texture)
  }
  var motion = Motion()
  @Published private(set) var motionActive = false
  var motionAnchor: CGPoint?
  private var lastMotionTime: Double?
  var zoomDirection = 0
  func stopMotion() {
    travelling = nil
    motion.stop()
    rotationTarget = nil
    motionActive = false
    lastMotionTime = nil
    zoomDirection = 0
  }
  /// Reduce Motion, from the environment: no inertia, no springs, no fades.
  /// What a gesture does directly is unchanged.
  var reduceMotion = false {
    didSet { tiles.fadeDuration = reduceMotion ? 0 : TilePresentation.fadeDuration }
  }
  func fling(
    pan: CGPoint = .zero, zoom: Double = 0, rotation: Double = 0, anchor: CGPoint? = nil
  ) {
    guard !reduceMotion else { return }
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
    motion.active || rotationTarget != nil || travelling != nil
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
    if reduceMotion {
      setAngle(Viewport.normalised(nearest))
      hapticTick()
      return
    }
    rotationTarget = Viewport.normalised(nearest)
    motion.rotationVelocity = 0
    requestRedraw()
    hapticTick()
  }
  /// Animates back to upright, for the compass button.
  func resetRotation() {
    guard mainViewport.angle != 0 else { return }
    if reduceMotion {
      setAngle(0)
      recordHistory()
      return
    }
    motion.rotationVelocity = 0
    rotationTarget = 0
    motionActive = true
    requestRedraw()
  }
  /// Turns straight to an angle about the view's centre, as the spring would
  /// arrive at it.
  private func setAngle(_ angle: Double) {
    rotate(Viewport.normalised(angle - mainViewport.angle))
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
    if travelling != nil {
      if advanceTravel(now: now) {
        requestRedraw()
      } else {
        motionActive = false
        lastMotionTime = nil
        zoomDirection = 0
      }
      return
    }
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
    // Turning a phone reshapes the view; a following crosshair that the new
    // shape leaves off screen comes back to the middle rather than vanishing.
    // A pinned one stays on its point, wherever that now is.
    if let marker = juliaMarker, !juliaPinned,
      !CGRect(origin: .zero, size: size).contains(marker)
    {
      centreJulia()
    }
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
  /// Whether a sheet covers the window.  The menu bar stays live above one,
  /// and its commands would otherwise act on the view hidden behind it.
  var isPresentingSheet: Bool {
    showPlaces || showMovie || showSettings || showHelp || showBenchmark
  }
  /// Everything the menus read, and nothing else: see `MenuState`.
  var menuState: MenuState {
    MenuState(
      canGoBack: canGoBack, canGoForward: canGoForward,
      isRotated: abs(mainViewport.angle) > 0.001, showJulia: showJulia,
      isPresentingSheet: isPresentingSheet)
  }
  /// Whether a command would do anything now, so a menu can say so.
  func canPerform(_ command: ExplorerCommand) -> Bool { menuState.allows(command) }
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
    // Opening, not toggling: key repeat on an iPad keyboard delivered the
    // shortcut twice and closed the sheet it had just opened.  A sheet closes
    // with Done, and the command is disabled while one is up.
    case .places: showPlaces = true
    case .bookmark: bookmarkCurrentView()
    case .julia: toggleJulia()
    case .swapJulia: swapJulia()
    case .movie: showMovie = true
    case .benchmark: showBenchmark = true
    case .help: showHelp = true
    }
  }
  /// The tiles draw themselves from the canvas's next frame; all a change
  /// needs is that frame, and a notice if there is no GPU to draw it.
  func requestRender() {
    guard isActive else { return }
    requestRedraw()
    error =
      GPUContext.shared == nil
      ? String(
        localized: "This device’s graphics processor isn’t available, so the set can’t be drawn.")
      : nil
  }
}

/// One bookmark to acknowledge: the place, whether it is new or was there
/// already, and a still of it once one has been taken.
struct BookmarkNotice: Identifiable, Equatable {
  let id = UUID()
  var place: Location
  var isNew: Bool
  var image: CGImage?
  static func == (a: BookmarkNotice, b: BookmarkNotice) -> Bool {
    a.id == b.id && a.place == b.place && a.image === b.image
  }
}
