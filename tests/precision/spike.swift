import Foundation
@main struct Spike {
 static func main() {
  for digits in [100,1000] {
   let bits = Int(ceil(Double(digits)*log2(10)))+64
   let unit = BigInt(1)<<bits
   let cr = -unit*743643887037151/1000000000000000
   let ci = unit*13182590390533/100000000000000
   var times:[Double]=[]; var checksum=0.0
   for _ in 0..<5 {
    let start = ProcessInfo.processInfo.systemUptime
    // Restart before escape: identical 1,000-step bounded orbit, 10 times.
    for _ in 0..<10 {
     var x=BigInt(0), y=BigInt(0)
     for _ in 0..<1000 { let xx=(x*x-y*y)>>bits; y=((2*x*y)>>bits)+ci; x=xx+cr }
     checksum += Double(x>>max(0,bits-40))/pow(2,40)
    }
    times.append(ProcessInfo.processInfo.systemUptime-start)
   }
   print("{\"library\":\"BigInt-5.7.0-fixed\",\"digits\":\(digits),\"bits\":\(bits),\"seconds\":\(times),\"checksum\":\(checksum)}")
  }
 }
}
