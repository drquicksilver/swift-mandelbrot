//
//  ContentView.swift
//  Mandelbrot
//
//  Created by Jules Bean on 19/01/2026.
//

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
    @State private var benchmarkRows: [BenchmarkRow] = []
    @State private var benchmarkSizes: [(Int, Int)] = [(128, 64), (256, 128), (512, 256), (1024, 512)]
    @State private var isBenchmarkRunning = false
    @State private var hasRunBenchmarks = false

    private enum Mode {
        case viewer
        case benchmark
    }

    private struct BenchmarkCell {
        let seconds: Double
        let pixelsPerSecond: Double
    }

    private struct BenchmarkRow: Identifiable {
        let id = UUID()
        let variant: String
        var results: [String: BenchmarkCell]
        var previewImage: CGImage?
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

                if activeMode == .benchmark {
                    Button("Copy as Markdown") {
                        copyBenchmarksAsMarkdown()
                    }
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(16)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(Color.black)
            .onChange(of: proxy.size) { _, newSize in
                renderSize = newSize
                renderToken += 1
            }
            .onAppear {
                renderSize = proxy.size
                renderToken += 1
                if activeMode == .benchmark, !hasRunBenchmarks {
                    ensureBenchmarkRows()
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
            .onChange(of: activeMode) { _, newMode in
                if newMode == .benchmark, !hasRunBenchmarks {
                    ensureBenchmarkRows()
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
                benchmarkHeader
                ForEach(benchmarkRows) { row in
                    benchmarkRowView(row)
                }
            }
            .padding(24)
        }
    }

    private var benchmarkHeader: some View {
        HStack {
            Text("Variant")
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 110, alignment: .leading)
            Text("Preview")
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 56, alignment: .leading)
            ForEach(benchmarkSizes, id: \.0) { size in
                Text("\(size.0)x\(size.1)")
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.caption)
        .padding(.bottom, 4)
    }

    private func benchmarkRowView(_ row: BenchmarkRow) -> some View {
        HStack {
            Text(row.variant)
                .foregroundStyle(.white)
                .frame(width: 110, alignment: .leading)
            Group {
                if let image = row.previewImage {
                    Image(decorative: image, scale: displayScale)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 48, height: 32)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.black.opacity(0.4))
                        .frame(width: 48, height: 32)
                }
            }
            .frame(width: 56, alignment: .leading)
            ForEach(benchmarkSizes, id: \.0) { size in
                let key = "\(size.0)x\(size.1)"
                if let cell = row.results[key] {
                    let mpx = cell.pixelsPerSecond / 1_000_000.0
                    Text(String(format: "%.3fs / %.2f Mpx/s", cell.seconds, mpx))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("—")
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .background(.black.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
            benchmarkRows = initialBenchmarkRows()
        }

        let variants = [
            "baseline",
            "scalar-tight",
            "coord-precompute",
            "unsafe-buffer",
            "float-math",
            "parallel",
            "simd4-float"
        ]

        var baselineRuns: [(Int, Int, Double)] = []
        var width = 128
        var height = 64
        while true {
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
            baselineRuns.append((width, height, seconds))
            if seconds > 2.0 {
                break
            }
            width *= 2
            height *= 2
        }

        let selectedRuns = Array(baselineRuns.suffix(4))
        let selectedSizes = selectedRuns.map { ($0.0, $0.1) }
        await MainActor.run {
            benchmarkSizes = selectedSizes
            benchmarkRows = initialBenchmarkRows()
        }

        if let previewSize = selectedSizes.first {
            for variant in variants {
                let image = await Task.detached(priority: .userInitiated) {
                    ContentView.renderPreviewImage(
                        variant: variant,
                        width: previewSize.0,
                        height: previewSize.1
                    )
                }.value
                await MainActor.run {
                    updateBenchmarkPreview(variant: variant, image: image)
                }
            }
        }

        for (width, height, seconds) in selectedRuns {
            let key = "\(width)x\(height)"
            let pixels = Double(width * height)
            let baselineRate = seconds > 0 ? pixels / seconds : 0
            await MainActor.run {
                updateBenchmarkRow(
                    variant: variants[0],
                    key: key,
                    seconds: seconds,
                    pixelsPerSecond: baselineRate
                )
            }
        }

        for (width, height) in selectedSizes {
            let key = "\(width)x\(height)"
            let pixels = Double(width * height)

            let tightenedSeconds = await Task.detached(priority: .userInitiated) {
                let start = Date()
                let iterations = MandelbrotRenderer.iterationsScalarTightened(
                    width: width,
                    height: height,
                    center: CGPoint(x: -0.5, y: 0.0),
                    scale: 1.0,
                    blockSize: 1
                )
                _ = MandelbrotColorizer.image(from: iterations)
                return Date().timeIntervalSince(start)
            }.value
            let tightenedRate = tightenedSeconds > 0 ? pixels / tightenedSeconds : 0
            await MainActor.run {
                updateBenchmarkRow(
                    variant: variants[1],
                    key: key,
                    seconds: tightenedSeconds,
                    pixelsPerSecond: tightenedRate
                )
            }

            let coordSeconds = await Task.detached(priority: .userInitiated) {
                let start = Date()
                let iterations = MandelbrotRenderer.iterationsCoordPrecompute(
                    width: width,
                    height: height,
                    center: CGPoint(x: -0.5, y: 0.0),
                    scale: 1.0,
                    blockSize: 1
                )
                _ = MandelbrotColorizer.image(from: iterations)
                return Date().timeIntervalSince(start)
            }.value
            let coordRate = coordSeconds > 0 ? pixels / coordSeconds : 0
            await MainActor.run {
                updateBenchmarkRow(
                    variant: variants[2],
                    key: key,
                    seconds: coordSeconds,
                    pixelsPerSecond: coordRate
                )
            }

            let unsafeSeconds = await Task.detached(priority: .userInitiated) {
                let start = Date()
                let iterations = MandelbrotRenderer.iterationsUnsafeBuffer(
                    width: width,
                    height: height,
                    center: CGPoint(x: -0.5, y: 0.0),
                    scale: 1.0,
                    blockSize: 1
                )
                _ = MandelbrotColorizer.image(from: iterations)
                return Date().timeIntervalSince(start)
            }.value
            let unsafeRate = unsafeSeconds > 0 ? pixels / unsafeSeconds : 0
            await MainActor.run {
                updateBenchmarkRow(
                    variant: variants[3],
                    key: key,
                    seconds: unsafeSeconds,
                    pixelsPerSecond: unsafeRate
                )
            }

            let floatSeconds = await Task.detached(priority: .userInitiated) {
                let start = Date()
                let iterations = MandelbrotRenderer.iterationsFloatMath(
                    width: width,
                    height: height,
                    center: CGPoint(x: -0.5, y: 0.0),
                    scale: 1.0,
                    blockSize: 1
                )
                _ = MandelbrotColorizer.image(from: iterations)
                return Date().timeIntervalSince(start)
            }.value
            let floatRate = floatSeconds > 0 ? pixels / floatSeconds : 0
            await MainActor.run {
                updateBenchmarkRow(
                    variant: variants[4],
                    key: key,
                    seconds: floatSeconds,
                    pixelsPerSecond: floatRate
                )
            }

            let parallelSeconds = await Task.detached(priority: .userInitiated) {
                let start = Date()
                let iterations = MandelbrotRenderer.iterationsParallel(
                    width: width,
                    height: height,
                    center: CGPoint(x: -0.5, y: 0.0),
                    scale: 1.0,
                    blockSize: 1
                )
                _ = MandelbrotColorizer.image(from: iterations)
                return Date().timeIntervalSince(start)
            }.value
            let parallelRate = parallelSeconds > 0 ? pixels / parallelSeconds : 0
            await MainActor.run {
                updateBenchmarkRow(
                    variant: variants[5],
                    key: key,
                    seconds: parallelSeconds,
                    pixelsPerSecond: parallelRate
                )
            }

            let simdSeconds = await Task.detached(priority: .userInitiated) {
                let start = Date()
                let iterations = MandelbrotRenderer.iterationsSIMD4Float(
                    width: width,
                    height: height,
                    center: CGPoint(x: -0.5, y: 0.0),
                    scale: 1.0,
                    blockSize: 1
                )
                _ = MandelbrotColorizer.image(from: iterations)
                return Date().timeIntervalSince(start)
            }.value
            let simdRate = simdSeconds > 0 ? pixels / simdSeconds : 0
            await MainActor.run {
                updateBenchmarkRow(
                    variant: variants[6],
                    key: key,
                    seconds: simdSeconds,
                    pixelsPerSecond: simdRate
                )
            }
        }

        await MainActor.run {
            isBenchmarkRunning = false
            hasRunBenchmarks = true
        }
    }

    private func initialBenchmarkRows() -> [BenchmarkRow] {
        let variants = [
            "baseline",
            "scalar-tight",
            "coord-precompute",
            "unsafe-buffer",
            "float-math",
            "parallel",
            "simd4-float"
        ]
        return variants.map { BenchmarkRow(variant: $0, results: [:], previewImage: nil) }
    }

    private func ensureBenchmarkRows() {
        if benchmarkRows.isEmpty {
            benchmarkRows = initialBenchmarkRows()
        }
    }

    private func updateBenchmarkRow(
        variant: String,
        key: String,
        seconds: Double,
        pixelsPerSecond: Double
    ) {
        guard let index = benchmarkRows.firstIndex(where: { $0.variant == variant }) else {
            return
        }
        benchmarkRows[index].results[key] = BenchmarkCell(
            seconds: seconds,
            pixelsPerSecond: pixelsPerSecond
        )
    }

    private func updateBenchmarkPreview(variant: String, image: CGImage?) {
        guard let index = benchmarkRows.firstIndex(where: { $0.variant == variant }) else {
            return
        }
        benchmarkRows[index].previewImage = image
    }

    private static func renderPreviewImage(variant: String, width: Int, height: Int) -> CGImage? {
        let iterations: MandelbrotIterations
        switch variant {
        case "baseline":
            iterations = MandelbrotRenderer.iterations(
                width: width,
                height: height,
                center: CGPoint(x: -0.5, y: 0.0),
                scale: 1.0,
                blockSize: 1
            )
        case "scalar-tight":
            iterations = MandelbrotRenderer.iterationsScalarTightened(
                width: width,
                height: height,
                center: CGPoint(x: -0.5, y: 0.0),
                scale: 1.0,
                blockSize: 1
            )
        case "coord-precompute":
            iterations = MandelbrotRenderer.iterationsCoordPrecompute(
                width: width,
                height: height,
                center: CGPoint(x: -0.5, y: 0.0),
                scale: 1.0,
                blockSize: 1
            )
        case "unsafe-buffer":
            iterations = MandelbrotRenderer.iterationsUnsafeBuffer(
                width: width,
                height: height,
                center: CGPoint(x: -0.5, y: 0.0),
                scale: 1.0,
                blockSize: 1
            )
        case "float-math":
            iterations = MandelbrotRenderer.iterationsFloatMath(
                width: width,
                height: height,
                center: CGPoint(x: -0.5, y: 0.0),
                scale: 1.0,
                blockSize: 1
            )
        case "parallel":
            iterations = MandelbrotRenderer.iterationsParallel(
                width: width,
                height: height,
                center: CGPoint(x: -0.5, y: 0.0),
                scale: 1.0,
                blockSize: 1
            )
        case "simd4-float":
            iterations = MandelbrotRenderer.iterationsSIMD4Float(
                width: width,
                height: height,
                center: CGPoint(x: -0.5, y: 0.0),
                scale: 1.0,
                blockSize: 1
            )
        default:
            return nil
        }
        return MandelbrotColorizer.image(from: iterations)
    }

    private func copyBenchmarksAsMarkdown() {
        let sizes = benchmarkSizes
        let header = ["Variant"] + sizes.map { "\($0.0)x\($0.1)" }
        let separator = Array(repeating: "---", count: header.count)

        var rows: [[String]] = [header, separator]
        for row in benchmarkRows {
            var cells: [String] = [row.variant]
            for size in sizes {
                let key = "\(size.0)x\(size.1)"
                if let cell = row.results[key] {
                    let mpx = cell.pixelsPerSecond / 1_000_000.0
                    cells.append(String(format: "%.3fs / %.2f Mpx/s", cell.seconds, mpx))
                } else {
                    cells.append("—")
                }
            }
            rows.append(cells)
        }

        let markdown = rows.map { "| " + $0.joined(separator: " | ") + " |" }.joined(separator: "\n")

#if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
#else
        UIPasteboard.general.string = markdown
#endif
    }
}

#Preview {
    ContentView()
}
