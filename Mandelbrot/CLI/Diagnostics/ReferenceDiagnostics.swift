// Reference orbits streamed in prefixes: a `--test-tiles` check, and
// `--benchmark-reference`, which times a cold automatic-depth view at 1e1000.

#if os(macOS)
  import Foundation
  import CoreGraphics
  import Metal

  extension TileDiagnostics {
    static func runReferenceBenchmark() async -> Int32 {
      do {
        guard let gpu = GPUContext.shared else { throw GPUFailure("GPU unavailable") }
        try await checkStreamedReferences(gpu)
        return 0
      } catch {
        FileHandle.standardError.write(Data("Reference benchmark failed: \(error)\n".utf8))
        return 1
      }
    }
    static func checkStreamedReferences(_ gpu: GPUContext) async throws {
      let view = try Viewport(real: "0", imag: "1", zoom: "1e1000")
      let limit = IterationPolicy.estimate(logScale: view.logScale)
      let store = TileStore(budgetBytes: 150 * 1024 * 1024)
      let start = ProcessInfo.processInfo.systemUptime
      var first: Double?
      store.onContentChange = {
        if first == nil && !store.records.isEmpty {
          first = ProcessInfo.processInfo.systemUptime - start
        }
      }
      defer { store.onContentChange = nil }
      store.update(
        viewport: view, size: CGSize(width: 256, height: 192), pixelWidth: 256,
        iterations: limit, override: nil, colouring: ColourSettings(density: 8))
      try await store.waitUntilReady()
      let ready = ProcessInfo.processInfo.systemUptime - start
      let cached = try await store.perturbationResources.references.reference(
        point: view.preciseCenter,
        iterations: 4097, bits: view.precisionBits)
      try require(
        cached.1 && cached.0.iterations < limit / 4,
        "Automatic depth generated the whole reference up front")
      print(
        "Cold automatic 1e1000: limit \(limit), first deep tile \((first ?? ready)*1000) ms, ready \(ready*1000) ms, reference length \(cached.0.values.count)"
      )
      // The exact centre pixel is capped, forcing a prefix extension and testing
      // that a temporary frontier is not treated as a completed reference.
      let samples = try gpu.texture(width: 1, height: 1, format: .rg32Uint)
      let region = PerturbationRegion(
        topLeft: view.preciseCenter, step: view.wideSpan,
        width: 1, height: 1, bits: view.precisionBits)
      let metrics = try await gpu.perturb(into: samples, region: region, iterations: 9000)
      try require(
        metrics.referenceExtensions > 0 && metrics.referenceSteps == 9000,
        "Streamed reference did not extend exactly once per missing orbit step")
      let data = try await gpu.readback(samples)
      try require(
        data.withUnsafeBytes { $0.load(as: UInt32.self) } == SampleRecord.capped,
        "Waiting for a reference prefix changed the pixel's capped status")
    }
  }
#endif
