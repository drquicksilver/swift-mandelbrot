import SwiftUI

struct ViewerView: View {
  @ObservedObject var model: ExplorerModel
  /// The main area shows the companion when the two are swapped; gestures always
  /// belong to whichever view fills it.
  var body: some View {
    GeometryReader { geometry in
      let imageCenter = model.viewport.screen(for: model.imageViewport.center, in: geometry.size)
      ZStack {
        Color.black
        if model.juliaSwapped {
          JuliaCanvas(model: model)
        } else if model.renderer.isGPU {
          GPUCanvas(model: model)
        } else if let image = model.image {
          Image(decorative: image, scale: 1).resizable().interpolation(.none)
            .scaleEffect(model.viewport.scale / model.imageViewport.scale)
            .offset(
              x: imageCenter.x - geometry.size.width / 2,
              y: imageCenter.y - geometry.size.height / 2)
        }
        PlatformInput(model: model)
          .accessibilityElement()
          .accessibilityLabel(model.juliaSwapped ? Text("Julia set") : Text("Mandelbrot set"))
          .accessibilityValue(model.location.suggestedName)
          .accessibilityHint(Text("Swipe up or down to zoom in or out."))
          .accessibilityAddTraits(.allowsDirectInteraction)
          .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.perform(.zoomIn)
            case .decrement: model.perform(.zoomOut)
            @unknown default: break
            }
          }
          .accessibilityAction(named: Text("Move left")) { model.perform(.left) }
          .accessibilityAction(named: Text("Move right")) { model.perform(.right) }
          .accessibilityAction(named: Text("Move up")) { model.perform(.up) }
          .accessibilityAction(named: Text("Move down")) { model.perform(.down) }
          .accessibilityAction(named: Text("Reset view")) { model.perform(.reset) }
        // The crosshair sits above the input surface but takes no hits: the
        // input view owns the pointer, and grabs the marker itself.
        JuliaMarker(model: model)
        if let rect = model.selection {
          Rectangle().stroke(.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
        }
      }.clipped()
    }
  }
}

/// Shows where c is on the Mandelbrot view.  It follows the pointer or finger
/// until it is pinned; a pinned marker is filled, can be dragged, and stays on
/// its point through panning and zooming.
struct JuliaMarker: View {
  @ObservedObject var model: ExplorerModel
  var body: some View {
    if let point = model.juliaMarker {
      let pinned = model.juliaPinned
      ZStack {
        // Each white stroke sits on a wider dark one, so the crosshair reads
        // on the pale bands of a palette as well as on the black of the set.
        cross.stroke(.black.opacity(0.6), lineWidth: 3)
        Circle().stroke(.black.opacity(0.6), lineWidth: 3.5).frame(width: 18, height: 18)
        Circle().fill(pinned ? Color.white.opacity(0.9) : .clear)
          .frame(width: 7, height: 7)
        Circle().stroke(.white, lineWidth: 1.5).frame(width: 18, height: 18)
        cross.stroke(.white, lineWidth: 1)
      }
      .frame(width: 28, height: 28)
      .position(x: point.x, y: point.y)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }
  private var cross: Path {
    Path { path in
      path.move(to: CGPoint(x: 0, y: 14))
      path.addLine(to: CGPoint(x: 28, y: 14))
      path.move(to: CGPoint(x: 14, y: 0))
      path.addLine(to: CGPoint(x: 14, y: 28))
    }
  }
}

/// The companion panel: the Julia set for the marked point, or the Mandelbrot
/// view when the two are swapped.  It has its own pan, zoom and rotate, and its
/// own button to swap it with the main area.
struct CompanionPanel: View {
  @ObservedObject var model: ExplorerModel
  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .bottomLeading) {
        if model.juliaSwapped {
          MandelbrotThumbnail(model: model)
        } else {
          JuliaCanvas(model: model)
        }
        CompanionInput(model: model)
        Text(
          model.juliaSwapped
            ? "Mandelbrot set" : "Julia set for \(model.juliaPoint)" as LocalizedStringKey
        )
        .font(.caption2.monospacedDigit())
        // One line, shrinking before it wraps: at the largest text sizes the
        // caption otherwise covered the whole image it describes.
        .lineLimit(1).minimumScaleFactor(0.5)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .padding(6)
        .background(.regularMaterial, in: Capsule()).padding(6)
        .allowsHitTesting(false)
        HStack(spacing: 4) {
          panelButton(
            String(localized: "Swap with the main view"), icon: "arrow.left.arrow.right.square"
          ) {
            model.swapJulia()
          }
          panelButton(
            model.juliaPinned
              ? CompanionPanel.unpin : String(localized: "Pin the crosshair where it is"),
            icon: model.juliaPinned ? "pin.fill" : "pin"
          ) { model.toggleJuliaPin() }
          panelButton(
            String(localized: "Reset the companion’s view"), icon: "arrow.counterclockwise"
          ) {
            model.resetPanel()
          }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
      }
      .onAppear { model.panelSize = geometry.size }
      .onChange(of: geometry.size) { _, size in model.panelSize = size }
    }
    // A container, so each button and the caption keep their own labels
    // rather than all reading as the panel.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("companionPanel")
    .accessibilityLabel(
      model.juliaSwapped ? Text("Mandelbrot companion") : Text("Julia companion"))
  }
  #if os(macOS)
    static let unpin = String(localized: "Let the crosshair follow the pointer again")
  #else
    static let unpin = String(localized: "Let the crosshair follow your finger again")
  #endif
  private func panelButton(_ title: String, icon: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      // The circle stays small so the three leave the image in view; the
      // target around it is the full 44 points.
      Image(systemName: icon).font(.caption)
        .frame(minWidth: 26, minHeight: 26)
        .background(.regularMaterial, in: Circle())
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(title)
  }
}

/// A live, non-interactive Mandelbrot view for the companion slot.
struct MandelbrotThumbnail: View {
  @ObservedObject var model: ExplorerModel
  var body: some View {
    ZStack {
      Color.black
      GPUCanvas(model: model)
    }
  }
}
