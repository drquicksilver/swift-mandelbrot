import Darwin
import Foundation
import Metal

enum DeviceDescription {
  static var current: String {
    var info = utsname()
    uname(&info)
    let capacity = MemoryLayout.size(ofValue: info.machine)
    var machine = withUnsafePointer(to: &info.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
    }
    #if os(macOS)
      var length = 0
      if sysctlbyname("hw.model", nil, &length, nil, 0) == 0, length > 0 {
        var model = [CChar](repeating: 0, count: length)
        let result = model.withUnsafeMutableBufferPointer {
          sysctlbyname("hw.model", $0.baseAddress, &length, nil, 0)
        }
        if result == 0 { machine = String(cString: model) }
      }
    #endif
    return
      "\(machine) · \(MTLCreateSystemDefaultDevice()?.name ?? "No GPU") · \(ProcessInfo.processInfo.operatingSystemVersionString)"
  }
}
