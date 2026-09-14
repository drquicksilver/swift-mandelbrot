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
    private var task: Task<Void, Never>?
    func cancel() { task?.cancel(); running = false }
    func run(viewport: Viewport, iterations: Int) {
        cancel(); rows = []; running = true
        task = Task {
            for size in [256,512] {
                for renderer in RendererID.allCases {
                    if Task.isCancelled { return }
                    status = "\(renderer.title), \(size) × \(size)"
                    var samples: [Double] = []
                    for run in 0..<4 {
                        if Task.isCancelled { return }
                        let start = DispatchTime.now().uptimeNanoseconds
                        let image = await RenderWorker.shared.renderImage(variant: renderer.rawValue,
                            width: size, height: size, center: viewport.center, scale: viewport.scale,
                            blockSize: 1, configuration: MandelbrotConfiguration(maxIterations: iterations))
                        if Task.isCancelled { return }
                        guard image != nil else { status = "\(renderer.title) unavailable"; running = false; return }
                        if run > 0 { samples.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1e9) }
                    }
                    rows.append(BenchmarkMeasurement(renderer: renderer, size: size, seconds: samples.sorted()[1]))
                }
            }
            running = false; status = "Complete"
        }
    }
    var markdown: String {
        var text = "# Mandelbrot benchmark\n\(ProcessInfo.processInfo.operatingSystemVersionString)\n\nMedian of 3 runs after 1 warmup; includes colour conversion.\n\n| Renderer | Size | Seconds | Mpx/s |\n| --- | --- | ---: | ---: |\n"
        for row in rows {
            text += String(format: "| %@ | %d² | %.6f | %.2f |\n", row.renderer.rawValue, row.size, row.seconds, Double(row.size*row.size)/row.seconds/1e6)
        }
        return text
    }
}

struct BenchmarkView: View {
    let viewport: Viewport
    let iterations: Int
    @StateObject private var model = BenchmarkModel()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Text("Current view · \(iterations) iterations")
                Button(model.running ? "Cancel" : "Run benchmarks") {
                    if model.running { model.cancel() } else { model.run(viewport: viewport, iterations: iterations) }
                }
                Text(model.status).font(.caption)
                ForEach(model.rows) { row in
                    LabeledContent("\(row.renderer.title) · \(row.size)²", value: String(format: "%.3f s", row.seconds))
                }
                ShareLink("Share results", item: model.markdown).disabled(model.rows.isEmpty)
            }.navigationTitle("Benchmarks")
                .toolbar { Button("Done") { dismiss() } }
        }.frame(minWidth: 320, idealWidth: 600, minHeight: 400)
            .onDisappear { model.cancel() }
    }
}
