import SwiftUI

#if os(macOS)
  import AppKit
  struct PlatformInput: NSViewRepresentable {
    var model: ExplorerModel
    func makeNSView(context: Context) -> MacInputView { MacInputView(model: model) }
    func updateNSView(_ view: MacInputView, context: Context) { view.model = model }
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
    override func viewDidMoveToWindow() {
      timer?.invalidate()
      timer = nil
      if window != nil {
        timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
          Task { @MainActor [weak self] in
            if let self, !self.model.renderer.isGPU {
              self.model.advanceMotion(now: ProcessInfo.processInfo.systemUptime)
            }
          }
        }
        RunLoop.main.add(timer!, forMode: .common)
      } else {
        model.stopMotion()
      }
    }
    override func mouseDown(with event: NSEvent) {
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
    }
    override func scrollWheel(with event: NSEvent) {
      model.stopMotion()
      model.zoom(
        exp(Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.008 : 0.12)),
        at: convert(event.locationInWindow, from: nil))
      // AppKit supplies trackpad momentum events; do not add a second inertia curve.
    }
    override func magnify(with event: NSEvent) {
      model.stopMotion()
      model.zoom(
        max(0.01, 1 + Double(event.magnification)), at: convert(event.locationInWindow, from: nil))
    }
    override func keyDown(with event: NSEvent) {
      let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
      for command in ExplorerCommand.allCases where command != .benchmark {
        var expected = NSEvent.ModifierFlags()
        if command.modifiers.contains(.command) { expected.insert(.command) }
        if command.modifiers.contains(.shift) { expected.insert(.shift) }
        let arrow: [ExplorerCommand: UInt16] = [.left: 123, .right: 124, .down: 125, .up: 126]
        let matches =
          arrow[command] == event.keyCode
          || (command == .help
            ? event.characters == "?"
            : event.charactersIgnoringModifiers?.lowercased()
              == String(command.key.character).lowercased())
        if matches && flags == expected {
          model.perform(command)
          return
        }
      }
      super.keyDown(with: event)
    }
  }
#else
  import UIKit
  struct PlatformInput: UIViewRepresentable {
    var model: ExplorerModel
    func makeUIView(context: Context) -> TouchInputView { TouchInputView(model: model) }
    func updateUIView(_ view: TouchInputView, context: Context) { view.model = model }
  }
  @MainActor final class TouchInputView: UIView, UIGestureRecognizerDelegate {
    var model: ExplorerModel
    private var displayLink: CADisplayLink?
    private var panning = false, pinching = false
    private var panVelocity = CGPoint.zero
    private var pinchVelocity = 0.0
    private var anchor = CGPoint.zero
    private func finishGesture() {
      if !panning && !pinching {
        model.fling(pan: panVelocity, zoom: pinchVelocity, anchor: anchor)
      }
    }
    init(model: ExplorerModel) {
      self.model = model
      super.init(frame: .zero)
      isMultipleTouchEnabled = true
      isAccessibilityElement = true
      accessibilityLabel = "Mandelbrot explorer"
      let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
      let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
      let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
      doubleTap.numberOfTapsRequired = 2
      let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTap(_:)))
      twoFingerTap.numberOfTouchesRequired = 2
      for recognizer in [pan, pinch, doubleTap, twoFingerTap] {
        recognizer.delegate = self
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
      } else {
        model.stopMotion()
      }
    }
    @objc private func tick() {
      if !model.renderer.isGPU { model.advanceMotion(now: ProcessInfo.processInfo.systemUptime) }
    }
    func gestureRecognizer(
      _ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer
    ) -> Bool {
      (a is UIPanGestureRecognizer && b is UIPinchGestureRecognizer)
        || (a is UIPinchGestureRecognizer && b is UIPanGestureRecognizer)
    }
    @objc private func pan(_ recognizer: UIPanGestureRecognizer) {
      if recognizer.state == .began {
        if !pinching {
          panVelocity = .zero
          pinchVelocity = 0
        }
        panning = true
        model.stopMotion()
      }
      let delta = recognizer.translation(in: self)
      model.pan(CGSize(width: delta.x, height: delta.y))
      recognizer.setTranslation(.zero, in: self)
      if recognizer.state == .ended {
        panning = false
        panVelocity = recognizer.velocity(in: self)
        finishGesture()
      }
      if recognizer.state == .cancelled {
        panning = false
        model.stopMotion()
      }
    }
    @objc private func pinch(_ recognizer: UIPinchGestureRecognizer) {
      if recognizer.state == .began {
        if !panning {
          panVelocity = .zero
          pinchVelocity = 0
        }
        pinching = true
        model.stopMotion()
      }
      let anchor = recognizer.location(in: self)
      model.zoom(Double(recognizer.scale), at: anchor)
      recognizer.scale = 1
      if recognizer.state == .ended {
        pinching = false
        pinchVelocity = Double(recognizer.velocity)
        self.anchor = anchor
        finishGesture()
      }
      if recognizer.state == .cancelled {
        pinching = false
        model.stopMotion()
      }
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
