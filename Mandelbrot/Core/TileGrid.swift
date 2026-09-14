import Foundation
import CoreGraphics

struct TileKey: Hashable, Sendable {
    let level: Int
    let x: Int64
    let y: Int64
    let anchorID: UInt64
    var parent: TileKey { TileKey(level:level-1,x:x >> 1,y:y >> 1,anchorID:anchorID) }
    var children: [TileKey] {
        [TileKey(level:level+1,x:x*2,y:y*2,anchorID:anchorID),
         TileKey(level:level+1,x:x*2+1,y:y*2,anchorID:anchorID),
         TileKey(level:level+1,x:x*2,y:y*2+1,anchorID:anchorID),
         TileKey(level:level+1,x:x*2+1,y:y*2+1,anchorID:anchorID)]
    }
    func ancestor(at level: Int) -> TileKey {
        let shift=self.level-level
        precondition(shift>=0 && shift<63)
        return TileKey(level:level,x:x >> shift,y:y >> shift,anchorID:anchorID)
    }
}
struct TileBounds: Sendable {
    let left: Double, top: Double, span: Double
    var center: CGPoint { CGPoint(x:left+span/2,y:top-span/2) }
}
struct TileGrid: Sendable {
    static let samples=256
    static let gutter=1
    static let textureSize=samples+2*gutter
    var anchor: CGPoint
    var anchorID: UInt64 = 0
    func span(at level: Int) -> Double { 3 * pow(2,-Double(level)) }
    func bounds(_ key: TileKey) -> TileBounds {
        let span=span(at:key.level)
        return TileBounds(left:anchor.x+Double(key.x)*span,top:anchor.y-Double(key.y)*span,span:span)
    }
    func idealLevel(viewport: Viewport,pixelWidth: Double) -> Double {
        log2(viewport.scale*max(1,pixelWidth)/Double(Self.samples))
    }
    func visible(viewport: Viewport,size: CGSize,level: Int) -> [TileKey] {
        let span=span(at:level),height=viewport.span*size.height/max(1,size.width)
        let minX=(viewport.center.x-viewport.span/2-anchor.x)/span
        let maxX=(viewport.center.x+viewport.span/2-anchor.x)/span
        let minY=(anchor.y-(viewport.center.y+height/2))/span
        let maxY=(anchor.y-(viewport.center.y-height/2))/span
        guard [minX,maxX,minY,maxY].allSatisfy({$0.isFinite && abs($0)<Double(Int64.max)/4}) else { return [] }
        let x0=Int64(floor(minX)),x1=max(x0,Int64(ceil(maxX))-1)
        let y0=Int64(floor(minY)),y1=max(y0,Int64(ceil(maxY))-1)
        guard (x1-x0+1)*(y1-y0+1)<=4096 else { return [] }
        return (y0...y1).flatMap { y in (x0...x1).map { TileKey(level:level,x:$0,y:y,anchorID:anchorID) } }
    }
    mutating func rebase(to anchor: CGPoint) { self.anchor=anchor;anchorID &+= 1 }
}
