import SwiftUI

struct ViewerView: View {
    @ObservedObject var model: ExplorerModel
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
                PlatformInput(model:model)
                if let rect = model.selection {
                    Rectangle().stroke(.white,style:StrokeStyle(lineWidth:1.5,dash:[5,4]))
                        .frame(width:rect.width,height:rect.height).position(x:rect.midX,y:rect.midY).allowsHitTesting(false)
                }
            }.clipped()
        }
    }
}
