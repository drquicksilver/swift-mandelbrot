import Combine
import SwiftUI

@MainActor final class ExplorerModel: ObservableObject {
  let tiles = TileStore()
  @Published var colouring = ColourSettings()
  @Published var isActive = true
  func setActive(_ active: Bool) {
    isActive = active
    if active {
      requestRender()
    } else {
      stopMotion()
      renderTask?.cancel()
      tiles.cancel()
    }
  }
  @Published var viewport = Viewport() { didSet { if viewport != oldValue { requestRender() } } }
  @Published var iterations = 200 { didSet { requestRender() } }
  @Published var rendererOverride: RendererID? { didSet { requestRender() } }
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
  var motionAnchor: CGPoint?
  private var lastMotionTime: Double?
  var zoomDirection = 0
  func stopMotion() {
    motion.stop()
    lastMotionTime = nil
    zoomDirection = 0
  }
  func fling(pan: CGPoint = .zero, zoom: Double = 0, anchor: CGPoint? = nil) {
    motion.velocity = SIMD2(max(-4000, min(4000, pan.x)), max(-4000, min(4000, pan.y)))
    motion.zoomVelocity = max(-4, min(4, zoom))
    motionAnchor = anchor
    lastMotionTime = ProcessInfo.processInfo.systemUptime
  }
  func advanceMotion(now: Double) {
    guard isActive, motion.active else {
      lastMotionTime = nil
      return
    }
    let dt = now - (lastMotionTime ?? now)
    lastMotionTime = now
    zoomDirection = motion.zoomVelocity > 0 ? 1 : (motion.zoomVelocity < 0 ? -1 : 0)
    let delta = motion.step(seconds: dt)
    var next = viewport
    next.pan(by: delta.pan, in: size)
    atPrecisionLimit = next.zoom(
      by: delta.zoom, at: motionAnchor ?? CGPoint(x: size.width / 2, y: size.height / 2), in: size,
      pixelWidth: pixelWidth)
    if atPrecisionLimit { motion.zoomVelocity = 0 }
    viewport = next
  }
  @Published var atPrecisionLimit = false
  var size = CGSize(width: 900, height: 600)
  var displayScale = 1.0
  private var renderTask: Task<Void, Never>?
  var pixelWidth: Double { size.width * displayScale }
  var renderer: RendererID {
    rendererOverride ?? viewport.recommendedRenderer(pixelWidth: pixelWidth)
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
    case .increaseIterations: iterations = min(65535, iterations * 2)
    case .decreaseIterations: iterations = max(1, iterations / 2)
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
    let iterations = iterations
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
