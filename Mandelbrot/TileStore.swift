import Combine
import CoreGraphics
import Foundation
import Metal

struct TileStatistics: Equatable, Codable {
  var preparationMS = 0.0, preparationP95MS = 0.0, preparationMaxMS = 0.0
  var referenceOrbits = 0, referenceCacheHits = 0
  var perturbationSkipped = 0
  var referenceMS = 0.0

  var sampledPixels = 0, coverageSampledPixels = 0, reusedPixels = 0
  var tiles = 0, bytes = 0, computed = 0, cancelled = 0, batches = 0, cacheHits = 0, evictions = 0
  var demandUpdates = 0
  var updateMS = 0.0, presentationFPS = 0.0
  var mipmaps = 0, prefetched = 0, pending = 0, budgetBytes = 0
  var longestBatchMS = 0.0, frameMS = 0.0, frameP95MS = 0.0, frameMaxMS = 0.0
}
@MainActor final class TileRecord {
  let key: TileKey
  let bounds: TileBounds
  let samples: MTLTexture
  var colour: MTLTexture
  let readyAt: Double
  let iterations: Int
  var cappedPixels = TileGrid.textureSize * TileGrid.textureSize
  var lastUsed: UInt64 = 0
  var isMip = false
  /// Coverage tiles are deliberately retained across ordinary LRU pressure.
  var isCoverage = false
  init(
    key: TileKey, bounds: TileBounds, samples: MTLTexture, colour: MTLTexture, readyAt: Double,
    iterations: Int
  ) {
    self.key = key
    self.bounds = bounds
    self.samples = samples
    self.colour = colour
    self.readyAt = readyAt
    self.iterations = iterations
  }
  var bytes: Int { samples.allocatedSize + colour.allocatedSize }
}

/// The single worker owns refinement and yields between bounded iteration batches.
/// Display commands only read complete textures. Palette swaps are transactional.
@MainActor final class TileStore: ObservableObject {
  @Published private(set) var statistics = TileStatistics()
  var grid = TileGrid(anchor: CGPoint(x: -0.5, y: 0))
  private(set) var records: [TileKey: TileRecord] = [:]
  private(set) var visible: [TileKey] = []
  private(set) var needed: Set<TileKey> = []
  private(set) var prefetch: Set<TileKey> = []
  private(set) var coverage: Set<TileKey> = []
  private var nearCoverage: Set<TileKey> = []
  private var sparseCoverage: Set<TileKey> = []
  private var deferredCoverage: Set<TileKey> = []
  private var coverageIndex: [TileRecord] = []
  private var rootIndex: [TileRecord] = []
  private(set) var viewport = Viewport()
  private(set) var size = CGSize(width: 1, height: 1)
  private(set) var colouring = ColourSettings()
  private(set) var iterations = 200
  private var override: RendererID?
  private var worker: Task<Void, Never>?
  private var generation: UInt64 = 0
  private var failed: Set<TileKey> = []
  private var failureAttempts: [TileKey: Int] = [:]
  private var operationFailures = 0
  private var retryTask: Task<Void, Never>?
  private var retryBlocked = false
  private var terminalFailure = false
  private let retryDelay: Duration
  private let beforeTileAllocation: ((TileKey) throws -> Void)?
  private(set) var lod = 0.0
  private(set) var fallback: [TileRecord] = []
  let minimumLevel = -2
  /// Levels of upsampling worth accepting to avoid presenting a stand-in.
  static let placeholderBlurTolerance = 2
  private let coverageTileLimit = 40
  var useBLA = true
  var hierarchicalBLA = true
  var fixedBLARadius = false
  let budgetBytes: Int
  let perturbationResources: PerturbationResources
  private var referenceBytes = 0
  private var needsReferenceReset = false
  private var boundsCache: [TileKey: TileBounds] = [:]
  // Reserve a third for transactional recolouring, one orbit-state buffer,
  // mip replacements and the two in-flight display frames.
  private var residentLimit: Int {
    let orbit = (iterations + 1) * MemoryLayout<ExtendedComplex>.stride
    let reserve =
      viewport.logScale > 32
      ? 4 * 1024 * 1024 + max(referenceBytes, min(perturbationResources.referenceBudget, orbit * 3))
        + orbit + (useBLA ? BilinearApproximation.storageBytes(iterations: iterations) * 3 : 0)
      : 2 * 1024 * 1024
    return max(2 * 1024 * 1024, (budgetBytes - reserve) * 2 / 3)
  }
  private var tileCost = 1024 * 1024
  private var rootReservation: Int { 4 * tileCost }
  private var coverageReservation: Int {
    // Coverage uses bytes left after the visible band, but always keeps room
    // for the four root cells surrounding an anchor. Under extreme pressure
    // the sampling LOD yields before that root footprint disappears.
    min(30 * 1024 * 1024, max(rootReservation, residentLimit - needed.count * tileCost))
  }
  private var coverageTileCapacity: Int {
    min(coverageTileLimit, coverageReservation / max(1, tileCost))
  }
  private var tick: UInt64 = 0
  private var counters = TileStatistics()
  private var needsRecolour = false
  private var suspended = false
  private var lastFramePublish = 0.0
  private var frameTimes: [Double] = []
  private var preparationTimes: [Double] = []
  private var presentationTimes: [Double] = []
  var onContentChange: (() -> Void)?
  private struct Demand: Equatable {
    let viewport: Viewport
    let size: CGSize
    let pixelWidth: Double
    let iterations: Int
    let override: RendererID?
    let colouring: ColourSettings
    let zoomDirection: Int
  }
  private var lastDemand: Demand?
  private(set) var error: String?
  var isIdle: Bool { worker == nil }
  var allVisibleReady: Bool { !visible.isEmpty && visible.allSatisfy { !needsSampling($0) } }
  var residentBytes: Int {
    records.values.reduce(0) { $0 + $1.bytes } + fallback.reduce(0) { $0 + $1.bytes }
  }
  var coverageBytes: Int {
    records.values.filter(\.isCoverage).reduce(0) { $0 + $1.bytes }
      + fallback.filter(\.isCoverage).reduce(0) { $0 + $1.bytes }
  }
  var coverageBudgetBytes: Int { coverageReservation }
  var tileResidentLimit: Int { residentLimit }

  init(
    budgetBytes: Int? = nil, retryDelay: Duration = .milliseconds(250),
    beforeTileAllocation: ((TileKey) throws -> Void)? = nil
  ) {
    self.retryDelay = retryDelay
    self.beforeTileAllocation = beforeTileAllocation
    #if os(iOS)
      let defaultBudget = 150 * 1024 * 1024
    #else
      let defaultBudget = 500 * 1024 * 1024
    #endif
    self.budgetBytes = max(8 * 1024 * 1024, budgetBytes ?? defaultBudget)
    perturbationResources = PerturbationResources(
      referenceBudget: min(self.budgetBytes / 4, 64 * 1024 * 1024))
  }
  func bounds(_ key: TileKey) -> TileBounds {
    if let record = records[key] { return record.bounds }
    if let value = boundsCache[key] { return value }
    let value = grid.bounds(key)
    if boundsCache.count >= 2048 { boundsCache.removeAll(keepingCapacity: true) }
    boundsCache[key] = value
    return value
  }
  private func invalidate() {
    generation &+= 1
    worker?.cancel()
    failed.removeAll()
    failureAttempts.removeAll()
    operationFailures = 0
    retryTask?.cancel()
    retryTask = nil
    retryBlocked = false
    terminalFailure = false
    error = nil
    // Preserve the last detailed working set through repeated invalidations.
    // The same key can have two iteration generations; newest complete data wins.
    var retained = Dictionary(fallback.map { ($0.key, $0) }, uniquingKeysWith: { _, new in new })
    for record in records.values where needed.contains(record.key) { retained[record.key] = record }
    // An old-anchor coverage tile is still a valid bounds-based safety net while
    // a new anchor is being populated, even if it does not intersect this frame.
    for record in records.values where record.isCoverage { retained[record.key] = record }
    fallback = retained.values.filter {
      $0.isCoverage || $0.bounds.intersects(viewport: viewport, size: size)
    }
    .sorted { $0.key.level > $1.key.level }
    records.removeAll()
    coverage.removeAll()
    nearCoverage.removeAll()
    sparseCoverage.removeAll()
    deferredCoverage.removeAll()
    rebuildCoverageIndex()
  }
  func update(
    viewport: Viewport, size: CGSize, pixelWidth: Double, iterations: Int,
    override: RendererID?, colouring: ColourSettings, zoomDirection: Int = 0
  ) {
    guard size.width > 0, size.height > 0 else { return }
    let demand = Demand(
      viewport: viewport, size: size, pixelWidth: pixelWidth,
      iterations: iterations, override: override, colouring: colouring, zoomDirection: zoomDirection
    )
    guard suspended || demand != lastDemand else { return }
    let start = ProcessInfo.processInfo.systemUptime
    defer { counters.updateMS = (ProcessInfo.processInfo.systemUptime - start) * 1000 }
    counters.demandUpdates += 1
    lastDemand = demand
    suspended = false
    tick &+= 1
    self.viewport = viewport
    self.size = size
    let limitChanged = self.iterations != iterations
    if self.override != override {
      invalidate()
    } else if limitChanged {
      generation &+= 1
      worker?.cancel()
      failed.removeAll()
      failureAttempts.removeAll()
      error = nil
      retryTask?.cancel()
      retryTask = nil
      retryBlocked = false
      terminalFailure = false
    }
    self.iterations = iterations
    self.override = override
    if viewport.deepCenter == nil && grid.deepAnchor != nil {
      invalidate()
      boundsCache.removeAll()
      // Restore the canonical shallow grid, matching a fresh session.
      grid.rebase(to: CGPoint(x: -0.5, y: 0))
      needsReferenceReset = true
    }
    lod = max(
      Double(minimumLevel),
      min(Viewport.maximumLogScale, grid.idealLevel(viewport: viewport, pixelWidth: pixelWidth)))
    var level = Int(ceil(lod))
    visible = grid.visible(viewport: viewport, size: size, level: level)
    if visible.isEmpty
      || visible.contains(where: { abs($0.x) > (1 << 30) || abs($0.y) > (1 << 30) })
    {
      invalidate()
      boundsCache.removeAll(keepingCapacity: true)
      grid.rebase(to: viewport.preciseCenter)
      visible = grid.visible(viewport: viewport, size: size, level: level)
    }
    func ancestors() -> Set<TileKey> {
      // Protect a local three-level band, not the entire path to the root.
      // A cold jump first gets a quarter-resolution preview, then actual detail.
      // Older ancestors remain ordinary LRU entries for zooming back out.
      Set(
        visible.flatMap { key in
          (max(minimumLevel, key.level - 2)...key.level).map { key.ancestor(at: $0) }
        })
    }
    needed = ancestors()
    // On unusually large drawables or a constrained cache, lower sampling LOD
    // rather than evicting visible ancestors or exceeding the memory budget.
    while needed.count * tileCost + rootReservation > residentLimit && level > minimumLevel {
      level -= 1
      lod = Double(level)
      visible = grid.visible(viewport: viewport, size: size, level: level)
      needed = ancestors()
    }
    let live = Set(visible)
    baseTransitions = baseTransitions.filter { live.contains($0.key) }
    configureCoverage(detailLevel: level)
    prefetch =
      zoomDirection > 0 && level < Int(Viewport.maximumLogScale)
      ? Set(visible.flatMap(\.children)) : []
    // Zoom-in prefetch remains lower priority than the coverage pyramid.
    for key in needed.union(coverage) {
      if let record = records[key] {
        if record.lastUsed != tick - 1 { counters.cacheHits += 1 }
        record.lastUsed = tick
      }
    }
    if self.colouring != colouring || limitChanged {
      self.colouring = colouring
      needsRecolour = true
      generation &+= 1
      worker?.cancel()
    }
    evict(reserving: 0)
    startWorker()
  }
  private func configureCoverage(detailLevel: Int) {
    // Near offsets make the next eight zoom-out steps cheap.  The sparse tail
    // makes a long zoom-out drawable without eagerly walking an ancestor chain.
    let nearOffsets = Array(1...8)
    let sparseOffsets = [12, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512]
    func group(offset: Int) -> Set<TileKey> {
      let target = max(minimumLevel, detailLevel - offset - 2)
      return Set(grid.visible(viewport: viewport, size: size, level: target, zoomOut: offset))
    }
    // Root is mandatory.  Then retain the useful 2–16× pinch-out levels before
    // the distant sparse tail; each group is all-or-nothing to avoid holes.
    let root = Set(
      grid.visible(
        viewport: viewport, size: size, level: minimumLevel,
        zoomOut: max(0, detailLevel - minimumLevel - 2)))
    var selected: Set<TileKey> = []
    func add(_ group: Set<TileKey>) -> Set<TileKey> {
      guard selected.count + group.count <= coverageTileCapacity else { return [] }
      selected.formUnion(group)
      return group
    }
    // A pathological aspect ratio can expose more root cells than the small
    // reservation.  Keep a deterministic subset rather than dropping root
    // coverage altogether; ordinary ancestor fallback still fills its edges.
    _ = add(
      Set(root.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }.prefix(coverageTileCapacity)))
    // Keep already completed root cells through a demand update.  The projected
    // footprint can move across a root-cell boundary during a gesture; dropping
    // the previous half before its replacement exists would reopen a hole.
    selected.formUnion(records.values.lazy.filter { $0.key.level == self.minimumLevel }.map(\.key))
    var near: Set<TileKey> = []
    for offset in nearOffsets where selected.count < coverageTileCapacity {
      near.formUnion(add(group(offset: offset)))
    }
    var sparse: Set<TileKey> = []
    for offset in sparseOffsets where selected.count < coverageTileCapacity {
      sparse.formUnion(add(group(offset: offset)))
    }
    deferredCoverage = deferredCoverage.intersection(selected)
    coverage = selected.subtracting(deferredCoverage)
    nearCoverage = near.subtracting(deferredCoverage)
    sparseCoverage = sparse.subtracting(deferredCoverage)
    for record in records.values { record.isCoverage = coverage.contains(record.key) }
    rebuildCoverageIndex()
  }
  private func deferCoverage(_ key: TileKey) {
    // A skip must remove the key from every scheduling source.  Otherwise the
    // main-actor worker can select the same over-budget key forever.
    deferredCoverage.insert(key)
    coverage.remove(key)
    nearCoverage.remove(key)
    sparseCoverage.remove(key)
  }
  private func trimCoverageToReservation() {
    // Deep reference/BLA storage can lower residentLimit after a coverage plan
    // was made.  Discard the farthest coverage first, preserving the root and
    // then near levels, rather than letting a stale reservation exceed memory.
    while coverageBytes > coverageReservation {
      if let record = records.values.filter({ $0.isCoverage && $0.key.level > minimumLevel })
        .min(by: {
          $0.key.level != $1.key.level ? $0.key.level < $1.key.level : $0.lastUsed < $1.lastUsed
        })
      {
        records.removeValue(forKey: record.key)
        deferCoverage(record.key)
        continue
      }
      if let index = fallback.indices.filter({ fallback[$0].isCoverage }).min(by: {
        fallback[$0].key.level != fallback[$1].key.level
          ? fallback[$0].key.level < fallback[$1].key.level
          : fallback[$0].lastUsed < fallback[$1].lastUsed
      }) {
        fallback.remove(at: index)
        continue
      }
      break
    }
    rebuildCoverageIndex()
  }
  private func rebuildCoverageIndex() {
    coverageIndex = (Array(records.values) + fallback)
      .filter(\.isCoverage)
      .sorted { $0.key.level > $1.key.level }
    rootIndex = (Array(records.values) + fallback)
      .filter { $0.key.level == minimumLevel }
  }
  func cancel() {
    suspended = true
    generation &+= 1
    worker?.cancel()
  }
  func retryFailedWork() {
    failed.removeAll()
    failureAttempts.removeAll()
    operationFailures = 0
    retryTask?.cancel()
    retryTask = nil
    retryBlocked = false
    terminalFailure = false
    error = nil
    startWorker()
  }
  private func handleFailure(_ error: Error, key: TileKey?) {
    self.error = String(describing: error)
    let attempts: Int
    if let key {
      failureAttempts[key, default: 0] += 1
      attempts = failureAttempts[key]!
    } else {
      operationFailures += 1
      attempts = operationFailures
    }
    if attempts >= 3 {
      if let key { failed.insert(key) }
      terminalFailure = true
      return
    }
    retryBlocked = true
    retryTask = Task { [weak self] in
      guard let self else { return }
      do { try await Task.sleep(for: self.retryDelay * attempts) } catch { return }
      self.retryBlocked = false
      self.retryTask = nil
      self.startWorker()
    }
  }
  private func needsSampling(_ key: TileKey) -> Bool {
    guard let record = records[key] else { return true }
    // Coverage is a bounded placeholder.  Its level estimate is enough to
    // colour a zoom-out and it must never compete with detail extension.
    if record.isCoverage { return false }
    return record.iterations < iterations && record.cappedPixels > 0
  }
  private func nextKey() -> TileKey? {
    func pending(_ keys: Set<TileKey>) -> Set<TileKey> {
      keys.filter { needsSampling($0) && !failed.contains($0) }
    }
    let root = pending(coverage.filter { $0.level == minimumLevel })
    let preview = pending(needed)
    let near = pending(nearCoverage)
    let sparse = pending(sparseCoverage)
    let zoomIn = pending(prefetch)
    let candidates =
      !root.isEmpty
      ? root : !preview.isEmpty ? preview : !near.isEmpty ? near : !sparse.isEmpty ? sparse : zoomIn
    guard
      !preview.isEmpty || !root.isEmpty || !near.isEmpty || !sparse.isEmpty
        || needed.count * tileCost + tileCost <= residentLimit
    else {
      return nil
    }
    if candidates == zoomIn && residentBytes + tileCost > residentLimit
      && !records.keys.contains(where: {
        !needed.contains($0) && !coverage.contains($0) && !prefetch.contains($0)
      })
    {
      return nil
    }
    guard let first = candidates.first else { return nil }
    let projection = TileProjection(origin: bounds(first), viewport: viewport, size: size)
    return candidates.min {
      if $0.level != $1.level { return $0.level < $1.level }
      let a = projection.center(of: bounds($0))
      let b = projection.center(of: bounds($1))
      return hypot(a.x - size.width / 2, a.y - size.height / 2)
        < hypot(b.x - size.width / 2, b.y - size.height / 2)
    }
  }
  private func evict(reserving bytes: Int) {
    retireFallback(now: ProcessInfo.processInfo.systemUptime)
    guard residentBytes + bytes > residentLimit else { return }
    for record in records.values.filter({
      !needed.contains($0.key) && !coverage.contains($0.key) && $0.key.level != minimumLevel
    })
    .sorted(by: {
      $0.lastUsed < $1.lastUsed
    }) {
      if residentBytes + bytes <= residentLimit { break }
      records.removeValue(forKey: record.key)
      counters.evictions += 1
    }
    // Coarse replacements are not a reason to discard old fine detail.
    retireFallback(now: ProcessInfo.processInfo.systemUptime)
    while residentBytes + bytes > residentLimit,
      let index = fallback.lastIndex(where: { !$0.isCoverage })
    { fallback.remove(at: index) }
    // Old generations are lowest-value coverage once new coverage has arrived.
    while residentBytes + bytes > residentLimit && !fallback.isEmpty { fallback.removeLast() }
    rebuildCoverageIndex()
  }
  private func publish() {
    // Flush the final frame window when work settles, so headless reports do not
    // omit the last fraction of a second between periodic HUD updates.
    if worker == nil, !frameTimes.isEmpty {
      let sorted = frameTimes.sorted()
      counters.frameP95MS = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
      counters.frameMaxMS = max(counters.frameMaxMS, sorted.last ?? 0)
    }
    if !preparationTimes.isEmpty {
      let sorted = preparationTimes.sorted()
      counters.preparationP95MS = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    }
    counters.tiles = records.count
    counters.bytes = residentBytes
    counters.budgetBytes = budgetBytes
    counters.pending = needed.union(coverage).filter { needsSampling($0) }.count
    statistics = counters
  }
  func recordPreparation(seconds: Double) {
    let ms = seconds * 1000
    counters.preparationMS = ms
    counters.preparationMaxMS = max(counters.preparationMaxMS, ms)
    preparationTimes.append(ms)
    if preparationTimes.count > 120 { preparationTimes.removeFirst() }
  }
  func recordFrame(seconds: Double, now: Double) {
    counters.frameMS = seconds * 1000
    counters.frameMaxMS = max(counters.frameMaxMS, seconds * 1000)
    frameTimes.append(seconds * 1000)
    if frameTimes.count > 120 { frameTimes.removeFirst() }
    if now - lastFramePublish > 0.25 {
      let sorted = frameTimes.sorted()
      counters.frameP95MS = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
      lastFramePublish = now
      publish()
    }
  }
  func recordPresentation(at time: Double) {
    guard time > 0 else { return }
    if let last = presentationTimes.last, time - last > 0.25 { presentationTimes.removeAll() }
    presentationTimes.append(time)
    if presentationTimes.count > 120 { presentationTimes.removeFirst() }
    if presentationTimes.count > 1, let first = presentationTimes.first, time > first {
      counters.presentationFPS = Double(presentationTimes.count - 1) / (time - first)
    }
  }
  /// A record is a stand-in when it was computed with a lower iteration limit
  /// than the current view demands.  Coverage tiles are adequate to fill a hole,
  /// but they are never a reason to hide detail the store already holds.  At
  /// shallow depths a coverage tile matches the view's limit and is not one.
  func isPlaceholder(_ record: TileRecord) -> Bool { record.iterations < iterations }
  private struct BaseTransition {
    var record: TileRecord
    var previous: TileRecord?
    var since: Double
  }
  private var baseTransitions: [TileKey: BaseTransition] = [:]
  /// Notes which record is presented as a cell's base and fades from the one it
  /// replaced.  Fades key on the moment of the switch, not on when a record was
  /// computed: a retained old-anchor or coverage tile has an ancient `readyAt`
  /// and would otherwise cut in at full strength on the frame it is selected.
  func presentBase(_ record: TileRecord, for key: TileKey, now: Double) -> (
    previous: TileRecord?, fade: Float
  ) {
    if let existing = baseTransitions[key], existing.record === record {
      return (existing.previous, TilePresentation.fade(readyAt: existing.since, now: now))
    }
    let previous = baseTransitions[key]?.record
    // A cell presented for the first time has nothing to fade from, so it keeps
    // the old behaviour and fades in on its own readiness.  Only a switch from
    // one presented record to another fades from the moment of the switch.
    let since = previous == nil ? record.readyAt : now
    baseTransitions[key] = BaseTransition(record: record, previous: previous, since: since)
    return (previous, TilePresentation.fade(readyAt: since, now: now))
  }
  func hasActiveFades(now: Double) -> Bool {
    if baseTransitions.values.contains(where: { now - $0.since < TilePresentation.fadeDuration }) {
      return true
    }
    return needed.contains { key in
      guard let record = records[key] else { return false }
      return now - record.readyAt < TilePresentation.fadeDuration
    }
  }
  private func recolour(_ gpu: GPUContext, generation: UInt64) async throws {
    let settings = colouring
    let limit = iterations
    let all = Array(records.values) + fallback
    var replacements: [(TileRecord, MTLTexture)] = []
    for record in all {
      try Task.checkCancellation()
      let colour = try gpu.texture(width: 258, height: 258, format: .rgba8Unorm)
      _ = try await gpu.colour(record.samples, into: colour, settings: settings, iterations: limit)
      replacements.append((record, colour))
    }
    try Task.checkCancellation()
    guard self.generation == generation else { throw CancellationError() }
    for (record, colour) in replacements {
      record.colour = colour
      record.isMip = false
    }
    needsRecolour = false
    onContentChange?()
    // Rebuild bottom-up from the new palette, never reuse old colour mipmaps.
    for key in Set(records.keys.map(\.parent)).sorted(by: { $0.level > $1.level }) {
      try await averageParent(of: key.children[0], gpu: gpu, generation: generation, cascade: false)
    }
  }
  private func averageParent(
    of child: TileKey, gpu: GPUContext, generation: UInt64, cascade: Bool = true
  ) async throws {
    var key = child.parent
    while key.level >= minimumLevel, let parent = records[key] {
      let children = key.children.compactMap { records[$0] }
      guard children.count == 4, children.allSatisfy({ !needsSampling($0.key) }) else { break }
      try Task.checkCancellation()
      let colour = try await gpu.average(children: children.map(\.colour), parent: parent.colour)
      try Task.checkCancellation()
      guard self.generation == generation else { throw CancellationError() }
      parent.colour = colour
      parent.isMip = true
      onContentChange?()
      counters.mipmaps += 1
      if !cascade { break }
      key = key.parent
    }
  }
  private func startWorker() {
    guard !suspended, !retryBlocked, !terminalFailure, worker == nil, let gpu = GPUContext.shared,
      needsRecolour || nextKey() != nil
    else { return }
    let generation = self.generation
    worker = Task { [weak self] in
      guard let self else { return }
      defer {
        self.worker = nil
        self.publish()
        self.onContentChange?()
        self.startWorker()
      }
      var workingKey: TileKey?
      do {
        if self.needsReferenceReset {
          // The previous worker has stopped before clearing its shared resources.
          await self.perturbationResources.references.clear()
          self.perturbationResources.clearScratch()
          self.referenceBytes = 0
          self.needsReferenceReset = false
          try Task.checkCancellation()
        }
        if self.needsRecolour { try await self.recolour(gpu, generation: generation) }
        while !Task.isCancelled, self.generation == generation, let key = self.nextKey() {
          workingKey = key
          try self.beforeTileAllocation?(key)
          let isCoverage = self.coverage.contains(key)
          let limit =
            isCoverage
            ? min(self.iterations, IterationPolicy.estimate(logScale: Double(key.level)))
            : self.iterations
          let previous = self.records[key]
          let resolution = TileGrid.textureSize
          self.evict(reserving: self.tileCost)
          // Prefetch never churns other prefetch entries endlessly.
          if !self.needed.contains(key) && self.residentBytes + self.tileCost > self.residentLimit {
            if self.coverage.contains(key) {
              self.deferCoverage(key)
            } else {
              self.prefetch.remove(key)
            }
            continue
          }
          let bounds = self.bounds(key)
          let samples = try gpu.texture(width: resolution, height: resolution, format: .rg32Uint)
          if let previous { try await gpu.copySamples(previous.samples, into: samples) }
          let colour = try gpu.texture(width: resolution, height: resolution, format: .rgba8Unorm)
          let renderer = PrecisionPolicy.renderer(
            logScale: Double(key.level), pixelWidth: 256, center: bounds.center,
            override: self.override)
          var cancelled = false
          if renderer == .perturbation {
            let bits = max(192, key.level + 128)
            let step = bounds.wideSpan * (1 / Double(TileGrid.samples))
            let topLeft = bounds.preciseOrigin.offset(x: step * -0.5, y: step * 0.5, bits: bits)
            var region = PerturbationRegion(
              topLeft: topLeft, step: step, width: resolution, height: resolution, bits: bits)
            // Reference selection is independent of the grid's indexing anchor.
            region.preferredReference = self.viewport.preciseCenter
            let metrics = try await gpu.perturb(
              into: samples, region: region, iterations: limit, useBLA: self.useBLA,
              hierarchicalBLA: self.hierarchicalBLA,
              resources: self.perturbationResources, preserveEscaped: previous != nil,
              fixedBLARadius: self.fixedBLARadius)
            self.referenceBytes = metrics.referenceBytes
            self.counters.batches += metrics.batches
            self.counters.referenceOrbits += metrics.references
            self.counters.referenceCacheHits += metrics.referenceCacheHits
            self.counters.referenceMS += metrics.referenceSeconds * 1000
            self.counters.perturbationSkipped += metrics.skippedIterations
            self.counters.longestBatchMS = max(self.counters.longestBatchMS, metrics.longestBatchMS)
            self.trimCoverageToReservation()
            self.evict(reserving: 0)
          } else {
            let step = bounds.span / Double(TileGrid.samples)
            guard
              let states = gpu.device.makeBuffer(
                length: resolution * resolution * 16, options: .storageModePrivate)
            else { throw GPUFailure("Orbit allocation failed") }
            var params = GPUParameters(
              viewport: Viewport(center: bounds.center, scale: 3 / bounds.span), width: resolution,
              height: resolution, iterations: limit, renderer: renderer)
            params.realMin = GPUParameters.split(bounds.left - step / 2)
            params.imagMax = GPUParameters.split(bounds.top + step / 2)
            params.stepX = GPUParameters.split(step)
            params.stepY = params.stepX
            params.smooth = 1
            params.padding = previous != nil ? 1 : 0
            var start = 0
            var batch = 64
            while start < limit {
              if Task.isCancelled
                || (!self.needed.contains(key) && !self.coverage.contains(key)
                  && !self.prefetch.contains(key))
              {
                cancelled = true
                break
              }
              let count = min(batch, limit - start)
              let time = try await gpu.resume(
                into: samples, states: states, parameters: params, start: start, count: count)
              start += count
              self.counters.batches += 1
              self.counters.longestBatchMS = max(self.counters.longestBatchMS, time * 1000)
              // Target 1 ms of measured GPU work; even the worst interior
              // batch is limited to 512 iterations over one 258² tile.
              batch = max(8, min(512, Int(Double(count) * min(2, 0.001 / max(time, 0.00001)))))
            }
          }
          if cancelled {
            self.counters.cancelled += 1
            continue
          }
          _ = try await gpu.colour(
            samples, into: colour, settings: self.colouring, iterations: limit)
          try Task.checkCancellation()
          guard self.generation == generation else { throw CancellationError() }
          let record = TileRecord(
            key: key, bounds: bounds, samples: samples, colour: colour,
            readyAt: ProcessInfo.processInfo.systemUptime, iterations: limit)
          let summary = try await gpu.sampleSummary(samples)
          try Task.checkCancellation()
          guard self.generation == generation else { throw CancellationError() }
          record.cappedPixels = summary.capped
          record.isCoverage = isCoverage
          self.counters.sampledPixels += previous?.cappedPixels ?? (resolution * resolution)
          if isCoverage {
            self.counters.coverageSampledPixels +=
              previous?.cappedPixels ?? (resolution * resolution)
          }
          self.counters.reusedPixels +=
            previous.map { resolution * resolution - $0.cappedPixels } ?? 0
          record.lastUsed = self.tick
          self.records[key] = record
          self.rebuildCoverageIndex()
          self.trimCoverageToReservation()
          self.evict(reserving: 0)
          self.failureAttempts.removeValue(forKey: key)
          self.error = nil
          self.tileCost = max(samples.allocatedSize + colour.allocatedSize, self.tileCost)
          self.counters.computed += 1
          if !self.needed.contains(key) && !self.coverage.contains(key) {
            self.counters.prefetched += 1
            self.prefetch.remove(key)
          }
          try await self.averageParent(of: key, gpu: gpu, generation: generation)
          self.publish()
          self.onContentChange?()
        }
      } catch is CancellationError { self.counters.cancelled += 1 } catch {
        self.handleFailure(error, key: workingKey)
      }
    }
  }
  func retireFallback(now: Double) {
    if allVisibleReady
      && visible.allSatisfy({ now - records[$0]!.readyAt >= TilePresentation.fadeDuration })
    {
      // Detail can fade away, but old-anchor coverage remains until the current
      // pyramid has its root tile.  This prevents re-anchoring from opening holes.
      let rootReady = coverage.contains { key in
        key.level == minimumLevel && records[key] != nil
      }
      fallback.removeAll { !$0.isCoverage || rootReady }
      rebuildCoverageIndex()
    }
  }
  func fallbackAvailable(for key: TileKey, maximumLevel: Int? = nil) -> TileRecord? {
    let cell = bounds(key)
    return fallback.filter { record in
      let b = record.bounds
      let r = cell.relative(to: b)
      return record.key.level <= (maximumLevel ?? key.level)
        && r.x >= -1e-12 && r.y >= -1e-12 && r.x + r.extent <= 1 + 1e-12
        && r.y + r.extent <= 1 + 1e-12
    }.min { $0.key.level > $1.key.level }
  }
  func bestAvailable(for key: TileKey) -> TileRecord? {
    var current: TileRecord?
    for level in stride(from: key.level, through: max(minimumLevel, key.level - 62), by: -1) {
      if let record = records[key.ancestor(at: level)] {
        current = record
        break
      }
    }
    let directCoverage = coverageIndex.first { record in
      guard record.key.level <= key.level else { return false }
      let r = bounds(key).relative(to: record.bounds)
      return r.x >= -1e-12 && r.y >= -1e-12 && r.x + r.extent <= 1 + 1e-12
        && r.y + r.extent <= 1 + 1e-12
    }
    let directRoot = rootIndex.first { record in
      let r = bounds(key).relative(to: record.bounds)
      return r.x >= -1e-12 && r.y >= -1e-12 && r.x + r.extent <= 1 + 1e-12
        && r.y + r.extent <= 1 + 1e-12
    }
    let old = fallbackAvailable(for: key)
    let ranked = [current, directCoverage, directRoot, old].compactMap { $0 }
    guard let best = ranked.max(by: { $0.key.level < $1.key.level }) else { return nil }
    guard isPlaceholder(best) else { return best }
    // Prefer real detail over a stand-in, but never blur by more than a factor
    // of four: past that the stand-in is the better picture of the two.
    return ranked.filter {
      !isPlaceholder($0) && $0.key.level >= best.key.level - Self.placeholderBlurTolerance
    }.max { $0.key.level < $1.key.level } ?? best
  }
  func waitUntilReady() async throws {
    while !isIdle || retryBlocked { try await Task.sleep(for: .milliseconds(2)) }
    if let error { throw GPUFailure(error) }
    guard allVisibleReady else { throw GPUFailure("Tile refinement incomplete") }
  }
  func waitUntilRootCoverageReady() async throws {
    let roots = coverage.filter { $0.level == minimumLevel }
    while !roots.allSatisfy({ records[$0] != nil }) && (!isIdle || retryBlocked) {
      try await Task.sleep(for: .milliseconds(2))
    }
    if let error { throw GPUFailure(error) }
    guard roots.allSatisfy({ records[$0] != nil }) else {
      throw GPUFailure("Root coverage refinement incomplete")
    }
  }
}
