#if os(macOS)
import Foundation
import CoreGraphics

/// Headless integration checks run the same tile store and compositor as MTKView.
@MainActor enum TileDiagnostics {
    static func require(_ condition: @autoclosure () -> Bool,_ message: String) throws {
        if !condition() { throw GPUFailure(message) }
    }
    static func run() async -> Int32 {
        do {
            guard let gpu=GPUContext.shared else { throw GPUFailure("GPU unavailable") }
            let store=TileStore(),size=CGSize(width:512,height:320)
            var view=Viewport()
            let start=DispatchTime.now().uptimeNanoseconds
            store.update(viewport:view,size:size,pixelWidth:512,iterations:200,override:nil,colouring:ColourSettings())
            try await store.waitUntilReady()
            let first=store.statistics.computed,records=store.records
            try require(first>0,"No tiles computed")
            let frame=try await TileCompositor.snapshot(store:store,viewport:view,width:512,height:320)
            let data=try await gpu.readback(frame)
            let center=(160*512+256)*4
            try require(data[center]<8 && data[center+1]<8 && data[center+2]<8,"Interior colour is incorrect")
            try require(Set(data).count>100,"Compositor is flat")
            view.pan(by:CGSize(width:20,height:0),in:size)
            store.update(viewport:view,size:size,pixelWidth:512,iterations:200,override:nil,colouring:ColourSettings())
            try await store.waitUntilReady()
            let shared=store.records.keys.filter { records[$0] != nil }
            try require(!shared.isEmpty,"Panning discarded overlapping tiles")
            for key in shared { try require(records[key]?.samples === store.records[key]?.samples,"Panning recomputed a cached tile") }
            let computed=store.statistics.computed
            store.update(viewport:view,size:size,pixelWidth:512,iterations:200,override:nil,colouring:ColourSettings(palette:.fire))
            try await store.waitUntilReady()
            try require(store.statistics.computed==computed,"Changing palette recomputed samples")
            let recoloured=try await TileCompositor.snapshot(store:store,viewport:view,width:512,height:320)
            let colourData=try await gpu.readback(recoloured)
            try require(colourData != data,"Palette recolouring did not change output")
            // Snapshot immediately after zooming, before the worker can refine.
            view.zoom(by:1.7,at:CGPoint(x:256,y:160),in:size,pixelWidth:512)
            store.update(viewport:view,size:size,pixelWidth:512,iterations:200,override:nil,colouring:ColourSettings(palette:.fire))
            let fallback=try await TileCompositor.snapshot(store:store,viewport:view,width:512,height:320,sentinel:true)
            let pixels=try await gpu.readback(fallback)
            var holes=0
            for i in stride(from:0,to:pixels.count,by:4) { if pixels[i]==255 && pixels[i+1]==0 && pixels[i+2]==255 { holes += 1 } }
            try require(holes==0,"Parent fallback left \(holes) uncovered pixels")
            try await store.waitUntilReady()
            try require(store.statistics.computed>computed,"Zoom did not refine new levels")
            let elapsed=Double(DispatchTime.now().uptimeNanoseconds-start)/1e9
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            print(String(decoding:try encoder.encode(store.statistics),as:UTF8.self))
            print("Tile integration passed in \(elapsed) seconds")
            return 0
        } catch {
            FileHandle.standardError.write(Data(("Tile test failed: \(error)\n").utf8));return 1
        }
    }
}
#endif
