import Darwin
import Foundation
import Metal

enum DeviceDescription {
  static var current: String {
    var info = utsname()
    uname(&info)
    let capacity = MemoryLayout.size(ofValue: info.machine)
    let machine = withUnsafePointer(to: &info.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
    }
    return
      "\(machine) · \(MTLCreateSystemDefaultDevice()?.name ?? "No GPU") · \(ProcessInfo.processInfo.operatingSystemVersionString)"
  }
}
