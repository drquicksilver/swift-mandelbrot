import Foundation

/// Metal ABI: delta' = A*delta + B*deltaC within radius. All values retain their
/// exponent, including CPU construction of arbitrarily long merged blocks.
struct BLAEntry: Sendable {
  var a, b: ExtendedComplex
  var radius: ExtendedFloat
  var length: UInt32
  var padding0: UInt32 = 0, padding1: UInt32 = 0, padding2: UInt32 = 0
}
struct BLATable: Sendable {
  let entries: [BLAEntry]
  let leafOffset: Int
}
extension ExtendedComplex {
  init(x: ExtendedFloat, y: ExtendedFloat) {
    self.x = x
    self.y = y
  }
  var wide: WideComplex { WideComplex(x: x.wide, y: y.wide) }
}
extension ExtendedFloat {
  var wide: WideReal { WideReal(Double(mantissa.x) + Double(mantissa.y), exponent: Int(exponent)) }
  var double: Double { wide.double }
}
enum BilinearApproximation {
  static let blockLength = 32
  static func storageBytes(iterations: Int) -> Int {
    var leaves = 1
    while leaves < (iterations + blockLength - 1) / blockLength { leaves *= 2 }
    return leaves * 2 * MemoryLayout<BLAEntry>.stride
  }
  private struct Block {
    var a = WideComplex(1, 0), b = WideComplex(0, 0), radius = WideReal(0)
    var length = 0
    var packed: BLAEntry {
      BLAEntry(a: a.packed, b: b.packed, radius: ExtendedFloat(radius), length: UInt32(length))
    }
  }
  static var disabled: BLATable {
    BLATable(entries: [Block().packed, Block().packed], leafOffset: 1)
  }
  private static func merge(_ first: Block, _ second: Block, dc: WideReal) -> Block {
    if first.length == 0 { return second }
    if second.length == 0 { return first }
    let bound: WideReal
    if first.a.magnitude.mantissa > 0 {
      bound = max(WideReal(0), second.radius - first.b.magnitude * dc).divided(
        by: first.a.magnitude)
    } else {
      bound = WideReal(0)
    }
    return Block(
      a: second.a * first.a, b: second.a * first.b + second.b, radius: min(first.radius, bound),
      length: first.length + second.length)
  }
  static func build(
    orbit: ReferenceOrbit, maximumDelta: WideReal, iterations: Int = Int.max,
    mergeGuardBits: Int = 5, jumpGuardBits: Int = 0
  ) throws
    -> BLATable
  {
    let count = min(orbit.values.count, iterations == Int.max ? Int.max : iterations + 1)
    let leaves = max(1, (count - 1 + blockLength - 1) / blockLength)
    var offset = 1
    while offset < leaves { offset *= 2 }
    var blocks = Array(repeating: Block(), count: offset * 2)
    let dc = maximumDelta * 1.000000000001
    for index in 0..<leaves {
      try Task.checkCancellation()
      let start = 1 + index * blockLength
      var block = Block()
      for n in start..<max(start, min(start + blockLength, count - 1)) {
        let z = orbit.values[n].wide
        let factor = z * WideComplex(2, 0)
        let radius =
          z.magnitude < WideReal(128)
          ? z.magnitude * WideReal(1, exponent: -44).divided(by: factor.magnitude + WideReal(1))
          : WideReal(0)
        let single = Block(a: factor, b: WideComplex(1, 0), radius: radius, length: 1)
        block = merge(block, single, dc: dc)
      }
      blocks[offset + index] = block
    }
    if offset > 1 {
      for index in stride(from: offset - 1, through: 1, by: -1) {
        if index.isMultiple(of: 128) { try Task.checkCancellation() }
        blocks[index] = merge(blocks[index * 2], blocks[index * 2 + 1], dc: dc)
        // Retain the validated production margin. Fixed per-jump allowances
        // remain an explicit diagnostic until full tiled validation passes.
        blocks[index].radius = blocks[index].radius * WideReal(1, exponent: -mergeGuardBits)
      }
    }
    return BLATable(
      entries: blocks.map { block in
        var entry = block.packed
        entry.radius = ExtendedFloat(block.radius * WideReal(1, exponent: -jumpGuardBits))
        return entry
      }, leafOffset: offset)
  }
}
