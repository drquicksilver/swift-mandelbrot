//
//  ContentView.swift
//  Mandelbrot
//
//  Created by Jules Bean on 19/01/2026.
//

import SwiftUI

struct ContentView: View {
    @Environment(\.displayScale) private var displayScale
    @State private var renderedImage: CGImage?
    @State private var progress: Double = 0.0
    @State private var renderSize: CGSize = .zero
    @State private var renderToken: Int = 0
    @State private var center = CGPoint(x: -0.5, y: 0.0)
    @State private var scale: Double = 1.0
    @GestureState private var gestureOffset: CGSize = .zero
    @GestureState private var gestureMagnification: CGFloat = 1.0
    @State private var previewOffset: CGSize = .zero
    @State private var previewMagnification: CGFloat = 1.0
    @State private var renderDuration: Double = 0.0
    @State private var renderResolution: CGSize = .zero
    @State private var activeMode: Mode = .benchmark
    @State private var benchmarkResults: [BenchmarkResult] = []
    @State private var isBenchmarkRunning = false
    @State private var hasRunBenchmarks = false

    private enum Mode {
        case viewer
        case benchmark
    }

    private struct BenchmarkResult: Identifiable {
        let id = UUID()
        let width: Int
        let height: Int
        let seconds: Double
        let pixelsPerSecond: Double
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                switch activeMode {
                case .viewer:
                    viewerPane
                case .benchmark:
                    benchmarkPane
                }

                hudView

                Button("Reset View") {
                    resetView()
                }
                .keyboardShortcut("H", modifiers: [.shift])
                .opacity(0)

                Button("Toggle Mode") {
                    toggleMode()
                }
                .keyboardShortcut(.tab)
                .opacity(0)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(Color.black)
            .onChange(of: proxy.size) { newSize in
                renderSize = newSize
                renderToken += 1
            }
            .onAppear {
                renderSize = proxy.size
                renderToken += 1
                if activeMode == .benchmark, !hasRunBenchmarks {
                    Task {
                        await runBenchmarks()
                    }
                }
            }
            .task(id: renderToken) {
                let token = renderToken
                await renderMandelbrot(size: renderSize, token: token)
            }
            .gesture(panGesture(in: proxy.size))
            .simultaneousGesture(zoomGesture())
            .onChange(of: activeMode) { newMode in
                if newMode == .benchmark, !hasRunBenchmarks {
                    Task {
                        await runBenchmarks()
                    }
                }
            }
            .background(keyCaptureView)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder private var keyCaptureView: some View {
        #if os(macOS)
        KeyCaptureView {
            toggleMode()
        }
        #else
        EmptyView()
        #endif
    }

    private var viewerPane: some View {
        ZStack {
            if let renderedImage {
                Image(decorative: renderedImage, scale: displayScale)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFill()
                    .scaleEffect(previewMagnification * gestureMagnification)
                    .offset(
                        CGSize(
                            width: previewOffset.width + gestureOffset.width,
                            height: previewOffset.height + gestureOffset.height
                        )
                    )
            } else {
                ProgressView("Rendering Mandelbrot...")
                    .foregroundStyle(.white)
            }
        }
    }

    private var benchmarkPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Benchmark Mode")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                if isBenchmarkRunning {
                    ProgressView("Running benchmarks...")
                        .foregroundStyle(.white)
                }
                ForEach(benchmarkResults) { result in
                    HStack {
                        Text("\(result.width)x\(result.height)")
                            .foregroundStyle(.white)
                        Spacer()
                        Text(String(format: "%.3fs", result.seconds))
                            .foregroundStyle(.white.opacity(0.9))
                        Text(String(format: "%.0f px/s", result.pixelsPerSecond))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .padding(12)
                    .background(.black.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                if hasRunBenchmarks && benchmarkResults.isEmpty {
                    Text("No benchmark results yet.")
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(24)
        }
    }

    private func resetView() {
        center = CGPoint(x: -0.5, y: 0.0)
        scale = 1.0
        previewOffset = .zero
        previewMagnification = 1.0
        renderToken += 1
    }

    private func toggleMode() {
        activeMode = activeMode == .viewer ? .benchmark : .viewer
        if activeMode == .viewer {
            renderToken += 1
        }
    }

    private var hudView: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if activeMode == .viewer, progress < 1.0 {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 180)
                Text("Rendering \(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
            } else if activeMode == .viewer {
                Text("Resolution \(Int(renderResolution.width))x\(Int(renderResolution.height))")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
                Text(String(format: "Render %.2fs", renderDuration))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
            } else {
                Text("Benchmark mode")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(12)
        .background(.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(16)
    }

    private func panGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($gestureOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                let baseSpan = 3.0
                let span = baseSpan / scale
                let imagSpan = span * Double(size.height / max(1, size.width))
                let dx = Double(value.translation.width) / Double(max(1, size.width))
                let dy = Double(value.translation.height) / Double(max(1, size.height))

                center.x -= dx * span
                center.y += dy * imagSpan
                previewOffset = CGSize(
                    width: previewOffset.width + value.translation.width,
                    height: previewOffset.height + value.translation.height
                )
                renderToken += 1
            }
    }

    private func zoomGesture() -> some Gesture {
        MagnificationGesture()
            .updating($gestureMagnification) { value, state, _ in
                state = value
            }
            .onEnded { value in
                scale *= Double(value)
                previewMagnification *= value
                renderToken += 1
            }
    }

    private func renderMandelbrot(size: CGSize, token: Int) async {
        guard activeMode == .viewer else { return }
        guard size.width > 0, size.height > 0 else { return }
        let pixelWidth = max(1, Int(size.width * displayScale))
        let pixelHeight = max(1, Int(size.height * displayScale))
        let center = center
        let scale = scale
        let blockSizes = [64, 32, 16, 8, 4, 2, 1]
        let startTime = Date()

        await MainActor.run {
            progress = 0.0
            renderResolution = CGSize(width: pixelWidth, height: pixelHeight)
        }

        for (index, blockSize) in blockSizes.enumerated() {
            let image = await Task.detached(priority: .userInitiated) {
                let iterations = MandelbrotRenderer.iterations(
                    width: pixelWidth,
                    height: pixelHeight,
                    center: center,
                    scale: scale,
                    blockSize: blockSize
                )
                return MandelbrotColorizer.image(from: iterations)
            }.value

            await MainActor.run {
                if let image {
                    renderedImage = image
                }
                progress = Double(index + 1) / Double(blockSizes.count)
            }
        }

        await MainActor.run {
            renderDuration = Date().timeIntervalSince(startTime)
            progress = 1.0
            if token == renderToken {
                previewOffset = .zero
                previewMagnification = 1.0
            }
        }
    }

    private func runBenchmarks() async {
        await MainActor.run {
            isBenchmarkRunning = true
            benchmarkResults = []
        }

        let sizes = [(128, 64), (256, 128), (512, 256), (1024, 512)]
        var results: [BenchmarkResult] = []

        for (width, height) in sizes {
            let seconds = await Task.detached(priority: .userInitiated) {
                let start = Date()
                let iterations = MandelbrotRenderer.iterations(
                    width: width,
                    height: height,
                    center: CGPoint(x: -0.5, y: 0.0),
                    scale: 1.0,
                    blockSize: 1
                )
                _ = MandelbrotColorizer.image(from: iterations)
                return Date().timeIntervalSince(start)
            }.value
            let pixels = Double(width * height)
            let rate = seconds > 0 ? pixels / seconds : 0
            results.append(
                BenchmarkResult(
                    width: width,
                    height: height,
                    seconds: seconds,
                    pixelsPerSecond: rate
                )
            )
        }

        await MainActor.run {
            benchmarkResults = results
            isBenchmarkRunning = false
            hasRunBenchmarks = true
        }
    }
}

#Preview {
    ContentView()
}
