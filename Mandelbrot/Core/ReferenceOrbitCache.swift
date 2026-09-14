import Foundation

/// Caches reference values within an explicit caller-owned memory budget.
/// Preparation runs outside this actor: hits do not wait for unrelated misses.
actor ReferenceOrbitCache {
  let byteLimit: Int
  private var entries: [ReferenceOrbit] = []
  private struct Pending {
    let point: DeepPoint, bits: Int, iterations: Int
    let task: Task<ReferenceOrbit, Error>
    var waiters: Set<UUID>
  }
  private var pending: [UUID: Pending] = [:]
  private(set) var computations = 0
  private(set) var extensions = 0
  init(byteLimit: Int = 4 * 1024 * 1024) { self.byteLimit = max(1024, byteLimit) }
  var bytes: Int {
    entries.reduce(0) { $0 + $1.storageBytes }
  }
  static func precision(_ bits: Int) -> Int { max(256, (bits + 255) / 256 * 256) }
  private func nearby(_ a: DeepPoint, _ b: DeepPoint, radius: WideReal) -> Bool {
    if radius.mantissa == 0 {
      return a.x - b.x == DeepNumber(0, bits: max(a.x.bits, b.x.bits))
        && a.y - b.y == DeepNumber(0, bits: max(a.y.bits, b.y.bits))
    }
    return hypot((a.x - b.x).wide / radius, (a.y - b.y).wide / radius) <= 1
  }
  func reference(
    point: DeepPoint, iterations: Int, bits requestedBits: Int, radius: WideReal = WideReal(0)
  ) async throws -> (ReferenceOrbit, Bool) {
    try Task.checkCancellation()
    let bits = Self.precision(requestedBits)
    if let index = entries.indices.filter({
      entries[$0].bits >= bits && (entries[$0].iterations >= iterations || entries[$0].escaped)
        && nearby(entries[$0].point, point, radius: radius)
    }).min(by: { entries[$0].bits < entries[$1].bits }) {
      let orbit = entries.remove(at: index)
      entries.append(orbit)
      return (orbit, true)
    }
    let waiter = UUID()
    let matching = pending.first { _, value in
      value.bits >= bits && value.iterations >= iterations
        && nearby(value.point, point, radius: radius)
    }?.key
    let key = matching ?? UUID()
    if matching != nil {
      pending[key]!.waiters.insert(waiter)
    } else {
      let candidate = entries.indices.filter {
        entries[$0].bits >= bits && entries[$0].finalX != nil
          && nearby(entries[$0].point, point, radius: radius)
      }.max { entries[$0].iterations < entries[$1].iterations }
      let prefix = candidate.map { entries[$0] }
      if prefix != nil { extensions += 1 }
      // Reserve for the incoming orbit before allocating it; keep the cache bounded.
      let reserve = min(byteLimit, (iterations + 1) * MemoryLayout<ExtendedComplex>.stride)
      while !entries.isEmpty && bytes + reserve > byteLimit { entries.removeFirst() }
      computations += 1
      pending[key] = Pending(
        point: point, bits: bits, iterations: iterations,
        task: Task.detached(priority: .userInitiated) {
          if let prefix { return try prefix.extended(to: iterations) }
          return try ReferenceOrbit.compute(point: point, iterations: iterations, bits: bits)
        }, waiters: [waiter])
    }
    let task = pending[key]!.task
    do {
      let orbit = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        Task { await self.cancel(waiter: waiter, key: key) }
      }
      if pending.removeValue(forKey: key) != nil {
        entries.removeAll {
          $0.point == orbit.point && $0.bits == orbit.bits && $0.iterations <= orbit.iterations
        }
        let cost = orbit.storageBytes
        while !entries.isEmpty && (entries.count >= 3 || bytes + cost > byteLimit) {
          entries.removeFirst()
        }
        if cost <= byteLimit { entries.append(orbit) }
      }
      try Task.checkCancellation()
      return (orbit, matching != nil)
    } catch {
      cancel(waiter: waiter, key: key)
      throw error
    }
  }
  private func cancel(waiter: UUID, key: UUID) {
    guard var entry = pending[key] else { return }
    entry.waiters.remove(waiter)
    if entry.waiters.isEmpty {
      entry.task.cancel()
      pending.removeValue(forKey: key)
    } else {
      pending[key] = entry
    }
  }
}
