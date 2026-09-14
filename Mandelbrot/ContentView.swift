import SwiftUI

struct ContentView: View {
    @StateObject private var model = ExplorerModel()
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                ViewerView(model: model)
                if model.showHUD {
                    VStack(alignment: .trailing) {
                        Text(model.renderer.title)
                        Text("\(model.iterations) iterations · \(model.duration, specifier: "%.3f") s")
                    }.font(.caption.monospacedDigit()).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
                }
                if model.atPrecisionLimit {
                    Text("Maximum detail reached").font(.caption).padding(10)
                        .background(.regularMaterial, in: Capsule()).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 16)
                }
                if let error = model.error {
                    Text(error).padding().background(.regularMaterial).frame(maxWidth: .infinity,maxHeight: .infinity)
                }
            }
            .onAppear { model.resize(geometry.size, displayScale: displayScale) }
            .onChange(of: geometry.size) { _, size in model.resize(size, displayScale: displayScale) }
            .onChange(of: displayScale) { _, scale in model.resize(geometry.size, displayScale: scale) }
        }
        .background(.black)
        .toolbar {
            Button { model.perform(.reset) } label: { Label("Reset", systemImage: "house") }
            Button { model.showSettings = true } label: { Label("Settings", systemImage: "slider.horizontal.3") }
            Button { model.showHelp = true } label: { Label("Controls", systemImage: "questionmark.circle") }
        }
        .sheet(isPresented: $model.showDeveloper) { DeveloperPanel(model:model) }
        .sheet(isPresented: $model.showBenchmark) { BenchmarkView(viewport: model.viewport, iterations: model.iterations) }
        .sheet(isPresented: $model.showSettings) { AppearanceView(model:model) }
        .sheet(isPresented: $model.showHelp) { HelpView() }
        .focusedSceneValue(\.explorer, model)
    }
}
