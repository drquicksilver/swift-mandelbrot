import SwiftUI

#if os(macOS)
  import AppKit
  struct PlatformInput: NSViewRepresentable {
    var model: ExplorerModel
    func makeNSView(context: Context) -> MacInputView { MacInputView(model: model) }
    func updateNSView(_ view: MacInputView, context: Context) {
      view.model = model
      view.updateMotionClock()
    }
  }
  @MainActor final class MacInputView: NSView {
    var model: ExplorerModel
    private var last = CGPoint.zero
    private var start = CGPoint.zero
    private var previousTime = 0.0
    private var velocity = CGPoint.zero
    private var selecting = false
    private var timer: Timer?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(model: ExplorerModel) {
      self.model = model
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      for area in trackingAreas { removeTrackingArea(area) }
      addTrackingArea(
        NSTrackingArea(
          rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
      model.trackJulia(at: convert(event.locationInWindow, from: nil))
    }
    override func viewDidMoveToWindow() {
      if window == nil {
        model.stopMotion()
        model.interactionActive = false
      }
      updateMotionClock()
    }
    func updateMotionClock() {
      guard window != nil, model.isActive, !model.renderer.isGPU, model.isAnimating else {
        timer?.invalidate()
        timer = nil
        return
      }
      guard timer == nil else { return }
      timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.model.advanceMotion(now: ProcessInfo.processInfo.systemUptime)
          self.updateMotionClock()
        }
      }
      RunLoop.main.add(timer!, forMode: .common)
    }
    override func mouseDown(with event: NSEvent) {
      model.interactionActive = true
      window?.makeFirstResponder(self)
      model.stopMotion()
      last = convert(event.locationInWindow, from: nil)
      start = last
      previousTime = event.timestamp
      velocity = .zero
      selecting = event.modifierFlags.contains(.shift)
      if event.clickCount == 2 { model.zoom(2, at: last) }
    }
    override func mouseDragged(with event: NSEvent) {
      let point = convert(event.locationInWindow, from: nil)
      if selecting {
        model.selection = CGRect(
          x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x),
          height: abs(point.y - start.y))
      } else {
        let dt = max(0.001, event.timestamp - previousTime)
        let dx = point.x - last.x
        let dy = point.y - last.y
        velocity = CGPoint(x: dx / dt, y: dy / dt)
        model.pan(CGSize(width: dx, height: dy))
        model.trackJulia(at: point)
      }
      last = point
      previousTime = event.timestamp
    }
    override func mouseUp(with event: NSEvent) {
      if selecting, let rect = model.selection, rect.width > 3, rect.height > 3 {
        model.viewport.fit(rect, in: bounds.size, pixelWidth: model.pixelWidth)
      } else if event.timestamp - previousTime < 0.08 {
        model.fling(pan: velocity)
      }
      model.selection = nil
      selecting = false
      model.interactionActive = false
    }
    override func scrollWheel(with event: NSEvent) {
      if event.phase.contains(.began) { model.interactionActive = true }
      // Momentum events continue after the fingers lift.  The interaction ends
      // when momentum ends, not when the fingers do, so automatic depth waits
      // for the view to settle.
      let momentumEnded =
        event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)
      let phaseEnded = event.phase.contains(.ended) || event.phase.contains(.cancelled)
      if momentumEnded || (phaseEnded && event.momentumPhase.isEmpty) {
        model.interactionActive = false
      }
      model.stopMotion()
      let precise = event.hasPreciseScrollingDeltas
      let zooming = !precise || event.modifierFlags.contains(.command)
      if zooming {
        // Physical wheels, and command-scroll on a trackpad, zoom at the cursor.
        model.zoom(
          exp(Double(event.scrollingDeltaY) * (precise ? 0.008 : 0.12)),
          at: convert(event.locationInWindow, from: nil))
      } else {
        // Two-finger scrolling pans.  The deltas already follow the system's
        // natural-scrolling setting, and AppKit supplies the momentum, so this
        // must not add a second inertia curve.
        model.pan(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
      }
    }
    override func rotate(with event: NSEvent) {
      if event.phase.contains(.began) { model.interactionActive = true }
      model.stopMotion()
      // AppKit reports counterclockwise degrees; the view follows the fingers.
      model.applyTwist(
        -Double(event.rotation) * .pi / 180, at: convert(event.locationInWindow, from: nil))
      if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
        model.endTwist(at: convert(event.locationInWindow, from: nil))
        model.interactionActive = false
      }
    }
    override func magnify(with event: NSEvent) {
      if event.phase.contains(.began) { model.interactionActive = true }
      if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
        model.interactionActive = false
      }
      model.stopMotion()
      model.zoom(
        max(0.01, 1 + Double(event.magnification)), at: convert(event.locationInWindow, from: nil))
      // Magnify and rotate arrive interleaved; ending either ends the twist.
      if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
        model.endTwist(at: convert(event.locationInWindow, from: nil))
      }
    }
    override func keyDown(with event: NSEvent) {
      if let command = ExplorerCommand.matching(event) {
        model.perform(command)
        return
      }
      super.keyDown(with: event)
    }
  }
#else
  import UIKit
  struct PlatformInput: UIViewRepresentable {
    var model: ExplorerModel
    func makeUIView(context: Context) -> TouchInputView { TouchInputView(model: model) }
    func updateUIView(_ view: TouchInputView, context: Context) {
      view.model = model
      view.updateMotionClock()
    }
  }
  /// One gesture solves pan, zoom and rotation together from the touches
  /// themselves, so the point under each finger stays pinned.  Three separately
  /// updating recognisers could not agree on a single transform.
  @MainActor final class TouchInputView: UIView, UIGestureRecognizerDelegate {
    var model: ExplorerModel
    private var displayLink: CADisplayLink?
    private var tracked: [UITouch] = []
    private var previous: [CGPoint] = []
    private var previousTime = 0.0
    private var panVelocity = CGPoint.zero
    private var zoomVelocity = 0.0
    private var rotationVelocity = 0.0
    private var anchor = CGPoint.zero
    init(model: ExplorerModel) {
      self.model = model
      super.init(frame: .zero)
      isMultipleTouchEnabled = true
      isAccessibilityElement = true
      accessibilityLabel = "Mandelbrot explorer"
      let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
      doubleTap.numberOfTapsRequired = 2
      let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTap(_:)))
      twoFingerTap.numberOfTouchesRequired = 2
      for recognizer in [doubleTap, twoFingerTap] {
        recognizer.delegate = self
        recognizer.cancelsTouchesInView = false
        addGestureRecognizer(recognizer)
      }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func didMoveToWindow() {
      displayLink?.invalidate()
      displayLink = nil
      if window != nil {
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(
          minimum: 30, maximum: Float(window?.screen.maximumFramesPerSecond ?? 60),
          preferred: Float(window?.screen.maximumFramesPerSecond ?? 60))
        displayLink?.add(to: .main, forMode: .common)
        updateMotionClock()
      } else {
        model.interactionActive = false
        endTracking(cancelled: true)
        model.stopMotion()
      }
    }
    func updateMotionClock() {
      displayLink?.isPaused =
        !(window != nil && model.isActive && !model.renderer.isGPU && model.isAnimating)
    }
    @objc private func tick() {
      if !model.renderer.isGPU { model.advanceMotion(now: ProcessInfo.processInfo.systemUptime) }
      updateMotionClock()
    }
    func gestureRecognizer(
      _ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer
    ) -> Bool { true }
    private func snapshot() -> [CGPoint] { tracked.map { $0.location(in: self) } }
    private func beginTracking(_ touches: Set<UITouch>) {
      for touch in touches where tracked.count < 2 { tracked.append(touch) }
      previous = snapshot()
      previousTime = ProcessInfo.processInfo.systemUptime
      panVelocity = .zero
      zoomVelocity = 0
      rotationVelocity = 0
      model.interactionActive = true
      model.stopMotion()
    }
    private func endTracking(cancelled: Bool) {
      tracked.removeAll()
      previous.removeAll()
      model.endTwist(at: anchor)
      model.interactionActive = false
      if cancelled {
        model.stopMotion()
      } else {
        model.fling(
          pan: panVelocity, zoom: zoomVelocity, rotation: rotationVelocity, anchor: anchor)
      }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
      beginTracking(touches)
      if let point = previous.first { model.trackJulia(at: point) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard !tracked.isEmpty else { return }
      let current = snapshot()
      guard current.count == previous.count else {
        previous = current
        return
      }
      let now = ProcessInfo.processInfo.systemUptime
      let dt = max(1.0 / 240, now - previousTime)
      if current.count == 1 {
        let delta = CGSize(
          width: current[0].x - previous[0].x, height: current[0].y - previous[0].y)
        model.pan(delta)
        model.trackJulia(at: current[0])
        anchor = current[0]
        panVelocity = CGPoint(x: delta.width / dt, y: delta.height / dt)
        zoomVelocity = 0
        rotationVelocity = 0
      } else {
        // Rotate and scale about the previous midpoint, then translate it: that
        // is the unique transform pinning both fingers.
        let before = CGPoint(
          x: (previous[0].x + previous[1].x) / 2, y: (previous[0].y + previous[1].y) / 2)
        let after = CGPoint(
          x: (current[0].x + current[1].x) / 2, y: (current[0].y + current[1].y) / 2)
        let spanBefore = hypot(
          previous[1].x - previous[0].x, previous[1].y - previous[0].y)
        let spanAfter = hypot(current[1].x - current[0].x, current[1].y - current[0].y)
        let angleBefore = atan2(previous[1].y - previous[0].y, previous[1].x - previous[0].x)
        let angleAfter = atan2(current[1].y - current[0].y, current[1].x - current[0].x)
        let turn = Viewport.normalised(Double(angleAfter - angleBefore))
        let turned = model.applyTwist(turn, at: before)
        let scale = spanBefore > 1 ? Double(spanAfter / spanBefore) : 1
        model.zoom(scale, at: before)
        let delta = CGSize(width: after.x - before.x, height: after.y - before.y)
        model.pan(delta)
        anchor = after
        panVelocity = CGPoint(x: delta.width / dt, y: delta.height / dt)
        zoomVelocity = log2(max(0.001, scale)) / dt
        // Only rotation that passed the twist threshold can be flung.
        rotationVelocity = turned / dt
      }
      previous = current
      previousTime = now
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
      tracked.removeAll { touches.contains($0) }
      if tracked.isEmpty {
        // A quick lift keeps its fling; a held finish does not.
        let resting = ProcessInfo.processInfo.systemUptime - previousTime > 0.08
        if resting {
          panVelocity = .zero
          zoomVelocity = 0
          rotationVelocity = 0
        }
        endTracking(cancelled: false)
      } else {
        previous = snapshot()
        previousTime = ProcessInfo.processInfo.systemUptime
      }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
      tracked.removeAll { touches.contains($0) }
      if tracked.isEmpty { endTracking(cancelled: true) } else { previous = snapshot() }
    }
    @objc private func doubleTap(_ recognizer: UITapGestureRecognizer) {
      model.stopMotion()
      model.zoom(2, at: recognizer.location(in: self))
    }
    @objc private func twoFingerTap(_ recognizer: UITapGestureRecognizer) {
      model.stopMotion()
      model.zoom(0.5, at: recognizer.location(in: self))
    }
  }
#endif
