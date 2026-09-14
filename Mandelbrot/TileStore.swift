import Foundation
import Combine
import CoreGraphics
import Metal

struct TileStatistics: Equatable, Codable {
    var tiles=0, bytes=0, computed=0, cancelled=0, batches=0, cacheHits=0, evictions=0
    var longestBatchMS=0.0
}
@MainActor final class TileRecord {
    let key: TileKey
    let samples: MTLTexture
    var colour: MTLTexture
    let readyAt: Double
    var lastUsed: UInt64 = 0
    init(key: TileKey,samples: MTLTexture,colour: MTLTexture,readyAt: Double) {
        self.key=key;self.samples=samples;self.colour=colour;self.readyAt=readyAt
    }
    var bytes: Int { samples.allocatedSize+colour.allocatedSize }
}

/// One asynchronous worker owns refinement. Camera movement only changes demand;
/// overlapping work survives, while invisible work is cancelled between GPU batches.
@MainActor final class TileStore: ObservableObject {
    @Published private(set) var statistics=TileStatistics()
    var grid=TileGrid(anchor:CGPoint(x:-0.5,y:0))
    private(set) var records: [TileKey:TileRecord] = [:]
    private(set) var visible: [TileKey] = []
    private(set) var needed: Set<TileKey> = []
    private(set) var viewport=Viewport()
    private(set) var size=CGSize(width:1,height:1)
    private(set) var colouring=ColourSettings()
    private(set) var iterations=200
    private var override: RendererID?
    private var worker: Task<Void,Never>?
    private var generation: UInt64 = 0
    private var failed: Set<TileKey> = []
    private var fixedLevel: Int?
    private var counters=TileStatistics()
    var error: String?
    var isIdle: Bool { worker == nil }
    var allVisibleReady: Bool { visible.allSatisfy { records[$0] != nil } }

    func update(viewport: Viewport,size: CGSize,pixelWidth: Double,iterations: Int,
                override: RendererID?,colouring: ColourSettings,zoomDirection: Int = 0) {
        guard size.width>0,size.height>0 else { return }
        self.viewport=viewport;self.size=size
        if self.iterations != iterations || self.override != override {
            generation &+= 1;worker?.cancel();worker=nil;records.removeAll();failed.removeAll()
        }
        self.iterations=iterations;self.override=override
        let level=fixedLevel ?? max(-2,min(45,Int(floor(grid.idealLevel(viewport:viewport,pixelWidth:pixelWidth)))))
        fixedLevel=level
        visible=grid.visible(viewport:viewport,size:size,level:level)
        needed=Set(visible)
        if self.colouring != colouring {
            self.colouring=colouring
            generation &+= 1;worker?.cancel();worker=nil
            // Keep raw data; appearance changes recolour, never recompute samples.
            recolourRecords()
        }
        startWorker()
    }
    func cancel() { generation &+= 1;worker?.cancel();worker=nil }
    private func nextKey() -> TileKey? {
        needed.filter { records[$0] == nil && !failed.contains($0) }.min {
            let a=grid.bounds($0).center,b=grid.bounds($1).center
            return hypot(a.x-viewport.center.x,a.y-viewport.center.y)<hypot(b.x-viewport.center.x,b.y-viewport.center.y)
        }
    }
    private func publish() {
        counters.tiles=records.count;counters.bytes=records.values.reduce(0) {$0+$1.bytes}
        statistics=counters
    }
    private func recolourRecords() {
        guard let gpu=GPUContext.shared else { return }
        let generation=self.generation,settings=colouring,records=Array(records.values)
        worker=Task { [weak self] in
            do {
                var replacements: [(TileRecord,MTLTexture)] = []
                for record in records {
                    try Task.checkCancellation()
                    let colour=try gpu.texture(width:TileGrid.textureSize,height:TileGrid.textureSize,format:.rgba8Unorm)
                    _ = try await gpu.colour(record.samples,into:colour,settings:settings)
                    replacements.append((record,colour))
                }
                guard let self,self.generation==generation else { return }
                // Swap as a transaction: a frame never shows a patchwork of palettes.
                for (record,colour) in replacements { record.colour=colour }
                self.worker=nil;self.publish();self.startWorker()
            } catch {
                guard let self,self.generation==generation else { return }
                self.worker=nil;self.startWorker()
            }
        }
    }
    private func startWorker() {
        guard worker==nil,let gpu=GPUContext.shared,nextKey() != nil else { return }
        let generation=self.generation
        worker=Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled,self.generation==generation,let key=self.nextKey() {
                do {
                    let resolution=TileGrid.textureSize
                    let bounds=self.grid.bounds(key),step=bounds.span/Double(TileGrid.samples)
                    let samples=try gpu.texture(width:resolution,height:resolution,format:.r32Float)
                    let colour=try gpu.texture(width:resolution,height:resolution,format:.rgba8Unorm)
                    let renderer=self.override ?? Viewport(center:bounds.center,scale:3/bounds.span).recommendedRenderer(pixelWidth:256)
                    var params=GPUParameters(viewport:Viewport(center:bounds.center,scale:3/bounds.span),width:resolution,height:resolution,iterations:self.iterations,renderer:renderer)
                    params.realMin=GPUParameters.split(bounds.left-step/2)
                    params.imagMax=GPUParameters.split(bounds.top+step/2)
                    params.stepX=GPUParameters.split(step);params.stepY=params.stepX
                    params.smooth=1
                    var cancelled=false
                    for row in stride(from:0,to:resolution,by:16) {
                        if Task.isCancelled || !self.needed.contains(key) { cancelled=true;break }
                        params.rowStart=UInt32(row);params.rowCount=UInt32(min(16,resolution-row))
                        let time=try await gpu.compute(into:samples,parameters:params)
                        self.counters.batches += 1;self.counters.longestBatchMS=max(self.counters.longestBatchMS,time*1000)
                    }
                    if cancelled { self.counters.cancelled += 1;continue }
                    _ = try await gpu.colour(samples,into:colour,settings:self.colouring)
                    guard self.generation==generation,!Task.isCancelled else { break }
                    self.records[key]=TileRecord(key:key,samples:samples,colour:colour,readyAt:ProcessInfo.processInfo.systemUptime)
                    self.counters.computed += 1
                    // A conservative temporary limit; byte-budgeted LRU comes in stage d.
                    if self.records.count>256,let victim=self.records.keys.first(where:{!self.needed.contains($0)}) { self.records.removeValue(forKey:victim) }
                    self.publish()
                } catch {
                    if Task.isCancelled { break }
                    self.failed.insert(key);self.error=String(describing:error)
                }
            }
            if self.generation==generation { self.worker=nil;self.publish() }
        }
    }
    func waitUntilReady() async throws {
        while !isIdle { try await Task.sleep(for:.milliseconds(2)) }
        if let error { throw GPUFailure(error) }
        guard allVisibleReady else { throw GPUFailure("Tile refinement incomplete") }
    }
}
