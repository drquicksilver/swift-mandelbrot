import SwiftUI

struct ViewerView: View {
    @ObservedObject var model: ExplorerModel
    @State private var previousDrag = CGSize.zero
    @State private var previousMagnification = 1.0
    var body: some View {
        GeometryReader { geometry in
            let imageCenter = model.viewport.screen(for: model.imageViewport.center, in: geometry.size)
            ZStack {
                Color.black
                if model.renderer.isGPU {
                    GPUCanvas(model: model)
                } else if let image = model.image {
                    Image(decorative: image, scale: 1).resizable().interpolation(.none)
                        .scaleEffect(model.viewport.scale / model.imageViewport.scale)
                        .offset(x: imageCenter.x - geometry.size.width/2, y: imageCenter.y - geometry.size.height/2)
                }
            }.clipped().contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                model.pan(CGSize(width: value.translation.width - previousDrag.width,
                                 height: value.translation.height - previousDrag.height))
                previousDrag = value.translation
            }.onEnded { _ in previousDrag = .zero })
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                let anchor = CGPoint(x: value.startAnchor.x * geometry.size.width, y: value.startAnchor.y * geometry.size.height)
                model.zoom(value.magnification / previousMagnification, at: anchor)
                previousMagnification = value.magnification
            }.onEnded { _ in previousMagnification = 1 })
        }
    }
}
