// The eight-byte sample every GPU path writes, as Swift sees it when a sample
// texture is read back.  Mirrors Shaders/SampleRecord.h.

import Foundation

/// RG32Uint ABI: exact UInt32 escape iteration plus Float32 correction bits.
/// Reserved counts mark status; capped is unresolved, not proven interior.
struct SampleRecord: Sendable {
  var iteration: UInt32
  var correction: Float
  static let capped = UInt32.max
  static let unfinished = UInt32.max - 1
  static let glitched = UInt32.max - 2
  var legacyFloat: Float {
    iteration >= Self.glitched ? -1 : Float(iteration) + correction
  }
  static func floatSamples(_ records: Data) -> Data {
    records.withUnsafeBytes { bytes in
      let samples = bytes.bindMemory(to: Self.self).map(\.legacyFloat)
      return samples.withUnsafeBytes { Data($0) }
    }
  }
}
