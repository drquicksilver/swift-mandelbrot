import Combine
import SwiftUI

@MainActor final class ExplorerModel: ObservableObject {
  let tiles = TileStore()
  private var tileObservation: AnyCancellable?
  init() {
    // Settled views report their escaped counts; each report may lower the
    // automatic limit.  Delivered after the publishing call returns.
    tileObservation = tiles.$statistics.receive(on: DispatchQueue.main).sink { [weak self] _ in
      MainActor.assumeIsolated { self?.observeDepth() }
    }
  }
  @Published var colouring = ColourSettings()
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
        updateDepth()
        requestRender()
      }
    }
  }
  @Published private(set) var iterations = 200 { didSet { requestRender() } }
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
        if isAnimating { motionActive = true }
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
  @Published var showTileOverlay = false
  @Published var selection: CGRect?
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
    motion.rotationVelocity = max(-12, min(12, rotation))
    motionAnchor = anchor
    lastMotionTime = ProcessInfo.processInfo.systemUptime
    motionActive = motion.active
  }
  /// Rotation, gentle bounds and the compass all animate here, so the display
  /// keeps drawing while any of them is still moving.
  var isAnimating: Bool {
    motion.active || rotationTarget != nil || (!interactionActive && boundsNeeded)
  }
  private(set) var rotationTarget: Double?
  private var twist = 0.0
  var centreOfView: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }
  func rotate(_ delta: Double, at point: CGPoint? = nil) {
    guard delta.isFinite, delta != 0 else { return }
    rotationTarget = nil
    var next = viewport
    next.rotate(by: delta, at: point ?? centreOfView, in: size)
    viewport = next
  }
  /// A pinch ignores its first ten degrees of twist, so zooming does not leave
  /// the view tilted; past that the gesture rotates one to one.
  func applyTwist(_ delta: Double, at point: CGPoint) {
    guard delta.isFinite, delta != 0 else { return }
    let threshold = 10 * Double.pi / 180
    twist += delta
    guard abs(twist) > threshold else { return }
    let effective = twist > 0 ? twist - threshold : twist + threshold
    twist = twist > 0 ? threshold : -threshold
    rotate(effective, at: point)
  }
  /// Ends a twist and snaps to a right angle when within three degrees.
  func endTwist(velocity: Double = 0, at point: CGPoint? = nil) {
    twist = 0
    let quarter = Double.pi / 2
    let nearest = (viewport.angle / quarter).rounded() * quarter
    guard abs(Viewport.normalised(viewport.angle - nearest)) <= 3 * Double.pi / 180 else { return }
    guard viewport.angle != Viewport.normalised(nearest) else { return }
    rotationTarget = Viewport.normalised(nearest)
    motion.rotationVelocity = 0
    hapticTick()
  }
  /// Animates back to upright, for the compass button.
  func resetRotation() {
    guard viewport.angle != 0 else { return }
    motion.rotationVelocity = 0
    rotationTarget = 0
    motionActive = true
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
    if view.logScale < Viewport.restingLogScale - 1e-9 {
      let next = Motion.approach(
        from: view.logScale, to: Viewport.restingLogScale, rate: rate, seconds: seconds)
      view.zoom(by: pow(2, next - view.logScale), at: centreOfView, in: size, pixelWidth: pixelWidth)
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
  func advanceMotion(now: Double) {
    guard isActive, isAnimating else {
      lastMotionTime = nil
      return
    }
    let dt = now - (lastMotionTime ?? now)
    lastMotionTime = now
    zoomDirection = motion.zoomVelocity > 0 ? 1 : (motion.zoomVelocity < 0 ? -1 : 0)
    let delta = motion.step(seconds: dt)
    var next = viewport
    next.pan(by: delta.pan, in: size)
    let anchor = motionAnchor ?? centreOfView
    if delta.rotation != 0 { next.rotate(by: delta.rotation, at: anchor, in: size) }
    atPrecisionLimit = next.zoom(by: delta.zoom, at: anchor, in: size, pixelWidth: pixelWidth)
    if atPrecisionLimit && motion.zoomVelocity > 0 {
      // Bounce off the precision limit rather than stopping dead.
      motion.zoomVelocity = -min(1.5, motion.zoomVelocity / 3)
    }
    if let target = rotationTarget {
      let remaining = Viewport.normalised(target - next.angle)
      if abs(remaining) < 1e-4 {
        next.rotate(by: remaining, at: centreOfView, in: size)
        rotationTarget = nil
      } else {
        next.rotate(
          by: Motion.approach(from: 0, to: remaining, rate: 12, seconds: dt), at: centreOfView,
          in: size)
      }
    }
    if !interactionActive { _ = applyBounds(&next, seconds: dt) }
    viewport = next
    if motionActive != isAnimating {
      motionActive = isAnimating
      if !motionActive { observeDepth() }
    }
  }
  @Published var atPrecisionLimit = false
  /// Whether the resting view would spring: used to wake the display when an
  /// interaction ends outside the gentle bounds.
  var boundsNeeded: Bool {
    if viewport.logScale < Viewport.restingLogScale - 1e-9 { return true }
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
    viewport.pan(by: delta, in: size)
  }
  func zoom(_ factor: Double, at point: CGPoint? = nil) {
    zoomDirection = factor > 1 ? 1 : (factor < 1 ? -1 : 0)
    atPrecisionLimit = viewport.zoom(
      by: factor, at: point ?? CGPoint(x: size.width / 2, y: size.height / 2),
      in: size, pixelWidth: pixelWidth)
  }
  func perform(_ command: ExplorerCommand) {
    stopMotion()
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
    case .benchmark: showBenchmark.toggle()
    case .help: showHelp.toggle()
    }
  }
  func requestRender() {
    renderTask?.cancel()
    guard isActive else { return }
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
