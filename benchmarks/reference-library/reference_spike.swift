import Foundation

@main struct ReferenceSpike {
  static func main() throws {
    // Match uncached full-frame and precision-banded tile requests at 1e100.
    for bits in [461, 512] {
      let point = DeepPoint(
        x: try DeepNumber(decimal: CommandLine.arguments[1], bits: bits),
        y: try DeepNumber(decimal: CommandLine.arguments[2], bits: bits))
      var times: [Double] = []
      var lengths: [Int] = []
      var checksum = 0.0
      for _ in 0..<5 {
        let orbit = try ReferenceOrbit.compute(point: point, iterations: 60000, bits: bits)
        times.append(orbit.seconds)
        lengths.append(orbit.values.count)
        checksum += orbit.values.reduce(0) { $0 + Double($1.x.mantissa.x) }
      }
      print(
        "{\"library\":\"BigInt-5.7.0-saved-reference\",\"bits\":\(bits),\"seconds\":\(times),\"lengths\":\(lengths),\"checksum\":\(checksum)}"
      )
    }
  }
}
