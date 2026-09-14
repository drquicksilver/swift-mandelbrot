import Foundation
import Testing
@testable import MandelbrotCore

@Test func negativeTileParentsAndChildren() {
    let key=TileKey(level:3,x:-3,y:-1,anchorID:7)
    #expect(key.parent.x == -2 && key.parent.y == -1)
    #expect(key.parent.children.contains(key))
    #expect(key.ancestor(at:0) == TileKey(level:0,x:-1,y:-1,anchorID:7))
}
@Test func tileCoverageAndRelativeAnchors() {
    var grid=TileGrid(anchor:CGPoint(x:-0.5,y:0))
    let view=Viewport(),size=CGSize(width:512,height:512)
    let keys=grid.visible(viewport:view,size:size,level:1)
    #expect(keys.count==4)
    #expect(grid.idealLevel(viewport:view,pixelWidth:512)==1)
    let a=keys[0];grid.rebase(to:CGPoint(x:-0.743643987,y:0.131825974))
    #expect(grid.anchorID != a.anchorID)
    let deep=grid.visible(viewport:Viewport(center:grid.anchor,scale:1e10),size:size,level:35)
    #expect(!deep.isEmpty)
    #expect(deep.allSatisfy { abs($0.x)<10 && abs($0.y)<10 })
}
