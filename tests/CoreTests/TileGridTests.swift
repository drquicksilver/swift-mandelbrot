import Foundation
import Testing

@testable import MandelbrotCore

@Test func negativeTileParentsAndChildren() {
  let key = TileKey(level: 3, x: -3, y: -1, anchorID: 7)
  #expect(key.parent.x == -2 && key.parent.y == -1)
  #expect(key.parent.children.contains(key))
  #expect(key.ancestor(at: 0) == TileKey(level: 0, x: -1, y: -1, anchorID: 7))
}
@Test func tileCoverageAndRelativeAnchors() {
  var grid = TileGrid(anchor: CGPoint(x: -0.5, y: 0))
  let view = Viewport()
  let size = CGSize(width: 512, height: 512)
  let keys = grid.visible(viewport: view, size: size, level: 1)
  #expect(keys.count == 4)
  #expect(grid.idealLevel(viewport: view, pixelWidth: 512) == 1)
  let a = keys[0]
  grid.rebase(to: CGPoint(x: -0.743643987, y: 0.131825974))
  #expect(grid.anchorID != a.anchorID)
  let deep = grid.visible(
    viewport: Viewport(center: grid.anchor, scale: 1e10), size: size, level: 35)
  #expect(!deep.isEmpty)
  #expect(deep.allSatisfy { abs($0.x) < 10 && abs($0.y) < 10 })
}

@Test func projectedZoomOutCoverageStaysCoarse() {
  let grid = TileGrid(anchor: CGPoint(x: -0.5, y: 0))
  let view = Viewport(center: CGPoint(x: -0.743643887, y: 0.131825904), scale: 1e10)
  let size = CGSize(width: 320, height: 200)
  let detail = Int(ceil(grid.idealLevel(viewport: view, pixelWidth: 320)))
  let near = grid.visible(viewport: view, size: size, level: detail - 6, zoomOut: 4)
  let root = grid.visible(viewport: view, size: size, level: -2, zoomOut: detail)
  #expect(!near.isEmpty && near.count <= 16)
  #expect(!root.isEmpty && root.count <= 16)
  #expect(near.allSatisfy { $0.level == detail - 6 })
}

@Test func oversizedProjectedCoverageIsRejectedWithoutOverflow() {
  let grid = TileGrid(anchor: CGPoint(x: -0.5, y: 0))
  let keys = grid.visible(
    viewport: Viewport(center: CGPoint(x: -0.743643887, y: 0.131825904), scale: 128),
    size: CGSize(width: 1_170, height: 2_532), level: -2, zoomOut: 64)
  #expect(keys.isEmpty)
}

@Test func refinementFadesAndFractionalLevels() {
  #expect(TilePresentation.fade(readyAt: 1, now: 1) == 0)
  #expect(TilePresentation.fade(readyAt: 1, now: 1.0625) == 0.5)
  #expect(TilePresentation.fade(readyAt: 1, now: 2) == 1)
  #expect(TilePresentation.fineWeight(lod: 4.25, readyAt: 1, now: 1.0625) == 0.125)
  #expect(TilePresentation.fineWeight(lod: 4, readyAt: 1, now: 2) == 0)
}
