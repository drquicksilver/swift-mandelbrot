import Foundation
import Metal

/// One instance per tile worker. Scratch leases are returned synchronously on
/// success, failure and cancellation; overlapping callers receive distinct buffers.
final class PerturbationResources: @unchecked Sendable {
  let references: ReferenceOrbitCache
  let referenceBudget: Int
  private let lock = NSLock()
  private var spare: MTLBuffer?
  init(referenceBudget: Int) {
    self.referenceBudget = referenceBudget
    references = ReferenceOrbitCache(byteLimit: referenceBudget)
  }
  func acquire(device: MTLDevice, length: Int) throws -> MTLBuffer {
    lock.lock()
    let buffer = spare
    spare = nil
    lock.unlock()
    if let buffer, buffer.length >= length { return buffer }
    guard let buffer = device.makeBuffer(length: length, options: .storageModePrivate) else {
      throw GPUFailure("Perturbation state allocation failed")
    }
    return buffer
  }
  func recycle(_ buffer: MTLBuffer) {
    lock.lock()
    defer { lock.unlock() }
    if buffer.length >= (spare?.length ?? 0) { spare = buffer }
  }
}
