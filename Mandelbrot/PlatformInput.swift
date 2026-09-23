import SwiftUI

#if os(macOS)
  import AppKit
  /// A double click the views can trust.  AppKit counts a second press inside
  /// the double-click interval as a double click wherever it lands, and after
  /// a short drag too; this also asks that both presses were clicks, a few
  /// points apart at most.
  struct DoubleClick {
    static let tolerance = 5.0
    private var lastClick: CGPoint?
    /// Call from `mouseDown`, before anything else uses the event.
    func isDouble(_ event: NSEvent, at point: CGPoint) -> Bool {
      guard event.clickCount >= 2, let lastClick else { return false }
      return hypot(point.x - lastClick.x, point.y - lastClick.y) <= Self.tolerance
    }
    /// Call from `mouseUp` with where the press began and ended.
    mutating func released(from start: CGPoint, to end: CGPoint) {
      let still = hypot(end.x - start.x, end.y - start.y) <= Self.tolerance
      lastClick = still ? end : nil
    }
  }
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
    /// The crosshair, once the pointer has taken hold of it: a drag moves c
    /// instead of panning, and a click that barely moves toggles the pin.
    private var draggingMarker = false
    private var markerMoved = false
    private var clicks = DoubleClick()
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
      updateCursor(event.modifierFlags)
      model.trackJulia(at: convert(event.locationInWindow, from: nil))
    }
    override func viewDidMoveToWindow() {
      if window == nil {
        model.stopMotion()
        model.interactionActive = false
      } else {
        // The keys are the canvas's from the start, not only after a click.
        window?.makeFirstResponder(self)
      }
      updateMotionClock()
    }
    /// Shift turns a drag into framing a region, so the pointer says so.
    override func flagsChanged(with event: NSEvent) {
      updateCursor(event.modifierFlags)
      super.flagsChanged(with: event)
    }
    private func updateCursor(_ flags: NSEvent.ModifierFlags) {
      guard let window else { return }
      let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
      guard bounds.contains(point) else { return }
      (flags.contains(.shift) ? NSCursor.crosshair : NSCursor.arrow).set()
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
      draggingMarker = !selecting && model.isOnJuliaMarker(last)
      markerMoved = false
      if draggingMarker { return }
      if clicks.isDouble(event, at: last) {
        // Option reverses it, as it does for the zoom tool in most Mac apps.
        model.zoom(event.modifierFlags.contains(.option) ? 0.5 : 2, at: last)
      }
    }
    override func mouseDragged(with event: NSEvent) {
      let point = convert(event.locationInWindow, from: nil)
      if draggingMarker {
        if hypot(point.x - start.x, point.y - start.y) > 2 { markerMoved = true }
        model.dragJulia(to: point)
        last = point
        previousTime = event.timestamp
        return
      }
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
      clicks.released(from: start, to: convert(event.locationInWindow, from: nil))
      if draggingMarker {
        // A click on the crosshair, rather than a drag of it, pins or releases.
        if !markerMoved { model.toggleJuliaPin() }
        draggingMarker = false
        model.interactionActive = false
        return
      }
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
  /// The companion panel's own gestures: drag to pan, scroll or pinch to zoom,
  /// twist to rotate.  The panel is small and never deep, so it has no inertia
  /// and no gentle bounds -- it moves exactly as far as the fingers do.
  struct CompanionInput: NSViewRepresentable {
    var model: ExplorerModel
    func makeNSView(context: Context) -> PanelInputView { PanelInputView(model: model) }
    func updateNSView(_ view: PanelInputView, context: Context) { view.model = model }
  }
  @MainActor final class PanelInputView: NSView {
    var model: ExplorerModel
    private var last = CGPoint.zero
    private var start = CGPoint.zero
    private var clicks = DoubleClick()
    override var isFlipped: Bool { true }
    init(model: ExplorerModel) {
      self.model = model
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func mouseDown(with event: NSEvent) {
      last = convert(event.locationInWindow, from: nil)
      start = last
      if clicks.isDouble(event, at: last) {
        model.zoomPanel(event.modifierFlags.contains(.option) ? 0.5 : 2, at: last)
      }
    }
    override func mouseUp(with event: NSEvent) {
      clicks.released(from: start, to: convert(event.locationInWindow, from: nil))
    }
    override func mouseDragged(with event: NSEvent) {
      let point = convert(event.locationInWindow, from: nil)
      model.panPanel(CGSize(width: point.x - last.x, height: point.y - last.y))
      last = point
    }
    override func scrollWheel(with event: NSEvent) {
      let precise = event.hasPreciseScrollingDeltas
      let point = convert(event.locationInWindow, from: nil)
      if !precise || event.modifierFlags.contains(.command) {
        model.zoomPanel(exp(Double(event.scrollingDeltaY) * (precise ? 0.008 : 0.12)), at: point)
      } else {
        model.panPanel(
          CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
      }
    }
    override func magnify(with event: NSEvent) {
      model.zoomPanel(
        max(0.01, 1 + Double(event.magnification)),
        at: convert(event.locationInWindow, from: nil))
    }
    override func rotate(with event: NSEvent) {
      model.rotatePanel(
        -Double(event.rotation) * .pi / 180, at: convert(event.locationInWindow, from: nil))
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
    /// The crosshair, once a finger has taken hold of it.
    private var draggingMarker = false
    private var markerMoved = false
    private var markerStart = CGPoint.zero
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
      if tracked.isEmpty, let touch = touches.first,
        model.isOnJuliaMarker(touch.location(in: self))
      {
        draggingMarker = true
        markerMoved = false
        markerStart = touch.location(in: self)
        tracked = [touch]
        previous = snapshot()
        model.interactionActive = true
        model.stopMotion()
        return
      }
      beginTracking(touches)
      if let point = previous.first { model.trackJulia(at: point) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard !tracked.isEmpty else { return }
      if draggingMarker {
        guard let point = snapshot().first else { return }
        if hypot(point.x - markerStart.x, point.y - markerStart.y) > 4 { markerMoved = true }
        model.dragJulia(to: point)
        return
      }
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
      if draggingMarker {
        guard tracked.isEmpty else { return }
        // A tap on the crosshair, rather than a drag of it, pins or releases.
        if !markerMoved { model.toggleJuliaPin() }
        draggingMarker = false
        previous.removeAll()
        model.interactionActive = false
        return
      }
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
      if draggingMarker {
        guard tracked.isEmpty else { return }
        draggingMarker = false
        previous.removeAll()
        model.interactionActive = false
        return
      }
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
  /// The companion panel's own gestures: drag to pan, pinch to zoom, twist to
  /// rotate.  The panel is small and never deep, so it has no inertia -- it
  /// moves exactly as far as the fingers do.
  struct CompanionInput: UIViewRepresentable {
    var model: ExplorerModel
    func makeUIView(context: Context) -> PanelInputView { PanelInputView(model: model) }
    func updateUIView(_ view: PanelInputView, context: Context) { view.model = model }
  }
  @MainActor final class PanelInputView: UIView {
    var model: ExplorerModel
    private var tracked: [UITouch] = []
    private var previous: [CGPoint] = []
    init(model: ExplorerModel) {
      self.model = model
      super.init(frame: .zero)
      isMultipleTouchEnabled = true
      let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
      doubleTap.numberOfTapsRequired = 2
      doubleTap.cancelsTouchesInView = false
      addGestureRecognizer(doubleTap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func snapshot() -> [CGPoint] { tracked.map { $0.location(in: self) } }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
      for touch in touches where tracked.count < 2 { tracked.append(touch) }
      previous = snapshot()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
      let current = snapshot()
      guard !tracked.isEmpty, current.count == previous.count else {
        previous = current
        return
      }
      if current.count == 1 {
        model.panPanel(
          CGSize(width: current[0].x - previous[0].x, height: current[0].y - previous[0].y))
      } else {
        // The same transform the main view uses: rotate and scale about the
        // previous midpoint, then translate it.
        let before = CGPoint(
          x: (previous[0].x + previous[1].x) / 2, y: (previous[0].y + previous[1].y) / 2)
        let after = CGPoint(
          x: (current[0].x + current[1].x) / 2, y: (current[0].y + current[1].y) / 2)
        let spanBefore = hypot(previous[1].x - previous[0].x, previous[1].y - previous[0].y)
        let spanAfter = hypot(current[1].x - current[0].x, current[1].y - current[0].y)
        let angleBefore = atan2(previous[1].y - previous[0].y, previous[1].x - previous[0].x)
        let angleAfter = atan2(current[1].y - current[0].y, current[1].x - current[0].x)
        model.rotatePanel(
          Viewport.normalised(Double(angleAfter - angleBefore)), at: before)
        model.zoomPanel(spanBefore > 1 ? Double(spanAfter / spanBefore) : 1, at: before)
        model.panPanel(CGSize(width: after.x - before.x, height: after.y - before.y))
      }
      previous = current
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
      tracked.removeAll { touches.contains($0) }
      previous = snapshot()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
      tracked.removeAll { touches.contains($0) }
      previous = snapshot()
    }
    @objc private func doubleTap(_ recognizer: UITapGestureRecognizer) {
      model.zoomPanel(2, at: recognizer.location(in: self))
    }
  }
#endif
