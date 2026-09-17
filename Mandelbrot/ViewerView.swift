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
        if let rect = model.selection {
          Rectangle().stroke(.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
        }
      }.clipped()
    }
  }
}

/// The companion panel: the Julia set for the point under the cursor or finger,
/// or the Mandelbrot view when the two are swapped.  Tapping swaps them.
struct CompanionPanel: View {
  @ObservedObject var model: ExplorerModel
  var body: some View {
    ZStack(alignment: .bottomLeading) {
      if model.juliaSwapped {
        MandelbrotThumbnail(model: model)
      } else {
        JuliaCanvas(model: model)
      }
      Text(
        model.juliaSwapped
          ? "Mandelbrot"
          : String(format: "Julia c = %.4f%+.4fi", model.juliaC.x, model.juliaC.y)
      )
      .font(.caption2.monospacedDigit()).padding(6)
      .background(.regularMaterial, in: Capsule()).padding(6)
    }
    .contentShape(Rectangle())
    .onTapGesture { model.swapJulia() }
    .accessibilityIdentifier("companionPanel")
    .accessibilityLabel(model.juliaSwapped ? "Mandelbrot companion" : "Julia companion")
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
