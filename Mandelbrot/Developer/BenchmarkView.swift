import Combine
import SwiftUI

struct BenchmarkMeasurement: Identifiable {
  let renderer: RendererID
  let size: Int
  let seconds: Double
  var id: String { "\(renderer.rawValue)-\(size)" }
}

@MainActor final class BenchmarkModel: ObservableObject {
  @Published var rows: [BenchmarkMeasurement] = []
  @Published var running = false
  @Published var status = ""
  private var viewport = Viewport()
  private var iterations = 200
  private var kernelOnly = false
  private var task: Task<Void, Never>?
  func cancel() {
    task?.cancel()
    running = false
  }
  func run(viewport: Viewport, iterations: Int, kernelOnly: Bool = false) {
    self.viewport = viewport
    self.iterations = iterations
    self.kernelOnly = kernelOnly
    cancel()
    rows = []
    running = true
    task = Task {
      for size in [256, 512] {
        for renderer in RendererID.allCases where !kernelOnly || renderer.isGPU {
          if PrecisionPolicy.renderer(
            logScale: viewport.logScale, pixelWidth: Double(size), center: viewport.center,
            override: renderer) != renderer
          {
            continue
          }
          if !renderer.isGPU && iterations > 65535 { continue }
          if Task.isCancelled { return }
          status = "\(renderer.title), \(size) × \(size)"
          var samples: [Double] = []
          for run in 0..<4 {
            if Task.isCancelled { return }
            let start = DispatchTime.now().uptimeNanoseconds
            var kernelTime: Double?
            var success = false
            if renderer.isGPU, let gpu = GPUContext.shared {
              if let frame = try? await gpu.render(
                viewport: viewport, width: size, height: size, iterations: iterations,
                renderer: renderer)
              {
                kernelTime = frame.kernelSeconds
                success = true
              }
            } else {
              let image = await LabRenderer.shared.image(
                renderer, width: size, height: size,
                center: viewport.center, scale: viewport.scale,
                configuration: MandelbrotConfiguration(maxIterations: iterations))
              success = image != nil
            }
            if Task.isCancelled { return }
            guard success else {
              status = "\(renderer.title) unavailable"
              running = false
              return
            }
            if run > 0 {
              samples.append(
                kernelOnly
                  ? (kernelTime ?? 0) : Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
            }
          }
          rows.append(
            BenchmarkMeasurement(renderer: renderer, size: size, seconds: samples.sorted()[1]))
        }
      }
      running = false
      status = "Complete"
    }
  }
  var markdown: String {
    var text =
      "# Mandelbrot benchmark\n\(DeviceDescription.current)\nCenter: \(viewport.centerDescription); scale: \(viewport.scaleDescription); iterations: \(iterations)\nScope: \(kernelOnly ? "GPU compute only" : "CPU legacy / GPU smooth compute + colour; no display/readback")\n\nMedian of 3 runs after 1 warmup.\n\n| Renderer | Size | Seconds | Mpx/s |\n| --- | --- | ---: | ---: |\n"
    for row in rows {
      text += String(
        format: "| %@ | %d² | %.6f | %.2f |\n", row.renderer.rawValue, row.size, row.seconds,
        Double(row.size * row.size) / row.seconds / 1e6)
    }
    return text
  }
}

struct BenchmarkView: View {
  let viewport: Viewport
  let iterations: Int
  @State private var kernelOnly = false
  @StateObject private var model = BenchmarkModel()
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      List {
        Text("Current view · \(iterations) iterations")
        Toggle("GPU kernel only", isOn: $kernelOnly).disabled(model.running)
        Button(model.running ? "Cancel" : "Run benchmarks") {
          if model.running {
            model.cancel()
          } else {
            model.run(viewport: viewport, iterations: iterations, kernelOnly: kernelOnly)
          }
        }
        Text(model.status).font(.caption)
        if model.rows.isEmpty && !model.running {
          ContentUnavailableView(
            "No Results Yet", systemImage: "gauge.with.dots.needle.33percent",
            description: Text(
              "Run the benchmarks to time every renderer on this view. The results can be shared as a Markdown table."
            ))
        }
        ForEach(model.rows) { row in
          LabeledContent(
            "\(row.renderer.title) · \(row.size)²", value: String(format: "%.3f s", row.seconds))
        }
        ShareLink("Share results", item: model.markdown).disabled(model.rows.isEmpty)
      }.navigationTitle("Benchmarks")
        .toolbar { Button("Done") { dismiss() } }
    }.frame(minWidth: 320, idealWidth: 600, minHeight: 400)
      .onDisappear { model.cancel() }
  }
}
