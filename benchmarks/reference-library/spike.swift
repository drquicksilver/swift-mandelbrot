// The arithmetic half of the reference-library spike: ten 1,000-step orbits in
// the vendored BigInt's fixed point, at 100 and 1,000 digits.  spike.cpp does
// the same in Boost; README.md explains, reproduce.py builds and runs both.

import Foundation

@main struct Spike {
  static func main() {
    for digits in [100, 1000] {
      let bits = Int(ceil(Double(digits) * log2(10))) + 64
      let unit = BigInt(1) << bits
      let cr = -unit * 743_643_887_037_151 / 1_000_000_000_000_000
      let ci = unit * 13_182_590_390_533 / 100_000_000_000_000
      var times: [Double] = []
      var checksum = 0.0
      for _ in 0..<5 {
        let start = ProcessInfo.processInfo.systemUptime
        // Restart before escape: identical 1,000-step bounded orbit, 10 times.
        for _ in 0..<10 {
          var x = BigInt(0)
          var y = BigInt(0)
          for _ in 0..<1000 {
            let xx = (x * x - y * y) >> bits
            y = ((2 * x * y) >> bits) + ci
            x = xx + cr
          }
          checksum += Double(x >> max(0, bits - 40)) / pow(2, 40)
        }
        times.append(ProcessInfo.processInfo.systemUptime - start)
      }
      print(
        "{\"library\":\"BigInt-5.7.0-fixed\",\"digits\":\(digits),\"bits\":\(bits),\"seconds\":\(times),\"checksum\":\(checksum)}"
      )
    }
  }
}
