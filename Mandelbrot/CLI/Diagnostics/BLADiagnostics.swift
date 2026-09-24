// `--test-bla`: isolated bilinear-approximation jumps measured on the GPU from
// identical starting states, written as JSON for tests/cli/test_bla.py to check
// against an independent Decimal recurrence.

#if os(macOS)
  import Foundation
  import Metal

  @MainActor enum BLADiagnostics {
    private struct Case {
      var delta, dc: ExtendedComplex
      var start, entry: UInt32
      var padding0: UInt32 = 0, padding1: UInt32 = 0
    }
    static func run(fixture: String) async -> Int32 {
      do {
        guard let gpu = GPUContext.shared else { throw GPUFailure("GPU unavailable") }
        let f =
          try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: fixture)))
          as! [String: Any]
        let pipeline = try await gpu.device.makeComputePipelineState(
          function: gpu.library.makeFunction(name: "measureBLA")!)
        var reports: [[String: Any]] = []
        for name in ["i", "minibrot"] {
          let bits = name == "i" ? 3584 : 512
          let point = try DeepPoint(
            x: DeepNumber(decimal: name == "i" ? "0" : f["centerReal"] as! String, bits: bits),
            y: DeepNumber(decimal: name == "i" ? "1" : f["centerImag"] as! String, bits: bits))
          let orbit = try ReferenceOrbit.compute(point: point, iterations: 60000, bits: bits)
          let dc = WideReal(log2: name == "i" ? -1000 * log2(10) : -100 * log2(10))
          for (policy, merge, jump) in [("compound", 5, 0), ("fixed", 0, 5)] {
            let table = try BilinearApproximation.build(
              orbit: orbit, maximumDelta: dc,
              mergeGuardBits: merge, jumpGuardBits: jump)
            var cases: [Case] = []
            var metadata: [[String: Any]] = []
            var perLength: [UInt32: Int] = [:]
            for index in 1..<table.entries.count {
              let b = table.entries[index]
              guard b.length >= 32, b.length <= 16384, b.radius.mantissa.x > 0,
                perLength[b.length, default: 0] < 3
              else { continue }
              perLength[b.length, default: 0] += 1
              let level = Int(floor(log2(Double(index))))
              let first = 1 << level
              let start = 1 + (index - first) * (table.leafOffset / first) * 32
              for fraction in [0.0, 0.125, 0.5, 0.99] {
                let seed = WideComplex(
                  x: b.radius.wide * (fraction * 0.8), y: b.radius.wide * (fraction * 0.6)
                ).packed
                let offset = WideComplex(x: dc * 0.6, y: dc * -0.8).packed
                cases.append(
                  Case(delta: seed, dc: offset, start: UInt32(start), entry: UInt32(index)))
                func encode<T>(_ value: T) -> String {
                  var v = value
                  return withUnsafeBytes(of: &v) { Data($0).base64EncodedString() }
                }
                metadata.append([
                  "start": start, "length": Int(b.length), "fraction": fraction,
                  "delta": encode(seed), "dc": encode(offset), "a": encode(b.a), "b": encode(b.b),
                ])
              }
            }
            guard
              let references = gpu.device.makeBuffer(
                bytes: orbit.values, length: orbit.values.count * 32, options: .storageModeShared),
              let blocks = gpu.device.makeBuffer(
                bytes: table.entries, length: table.entries.count * 96, options: .storageModeShared),
              let inputs = gpu.device.makeBuffer(
                bytes: cases, length: cases.count * MemoryLayout<Case>.stride,
                options: .storageModeShared),
              let output = gpu.device.makeBuffer(
                length: cases.count * 64, options: .storageModeShared),
              let command = gpu.computeQueue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder()
            else { throw GPUFailure("BLA diagnostic allocation failed") }
            var count = UInt32(cases.count)
            encoder.setBuffer(references, offset: 0, index: 0)
            encoder.setBuffer(blocks, offset: 0, index: 1)
            encoder.setBuffer(inputs, offset: 0, index: 2)
            encoder.setBuffer(output, offset: 0, index: 3)
            encoder.setBytes(&count, length: 4, index: 4)
            gpu.dispatch(encoder, pipeline: pipeline, width: cases.count, height: 1)
            encoder.endEncoding()
            _ = try await gpu.submit(command)
            let raw = Data(bytes: output.contents(), count: cases.count * 64)
            let referenceData = orbit.values.withUnsafeBytes { Data($0) }
            reports.append([
              "scene": name, "policy": policy, "orbit": referenceData.base64EncodedString(),
              "cases": metadata, "results": raw.base64EncodedString(),
            ])
          }
        }
        let data = try JSONSerialization.data(withJSONObject: reports, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        return 0
      } catch {
        FileHandle.standardError.write(Data("BLA diagnostic failed: \(error)\n".utf8))
        return 1
      }
    }
  }
#endif
