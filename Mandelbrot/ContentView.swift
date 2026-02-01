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
    @GestureState private var gestureZoomAnchor: UnitPoint = .center
    @State private var previewOffset: CGSize = .zero
    @State private var previewMagnification: CGFloat = 1.0
    @State private var renderDuration: Double = 0.0
    @State private var renderResolution: CGSize = .zero
    @State private var showRenderProgress = false
    @State private var maxIterations: Int = 200
    @State private var renderVariant: String = "metal"
    @State private var selectionStart: CGPoint?
    @State private var selectionEnd: CGPoint?
    @State private var activeMode: Mode = .viewer
    @State private var benchmarkRows: [BenchmarkRow] = []
    @State private var benchmarkSizes: [(Int, Int)] = [(128, 64), (256, 128), (512, 256), (1024, 512)]
    @State private var isBenchmarkRunning = false
    @State private var hasRunBenchmarks = false
    @State private var benchmarkPhase: BenchmarkPhase = .phase2

    private enum Mode {
        case viewer
        case benchmark
    }

    private enum BenchmarkPhase {
        case phase1
        case phase2

        var variants: [String] {
            switch self {
            case .phase1:
                return [
                    "baseline",
                    "scalar-tight",
                    "coord-precompute",
                    "unsafe-buffer",
                    "float-math",
                    "parallel",
                    "simd4-float"
                ]
            case .phase2:
                return [
                    "baseline",
                    "parallel",
                    "metal",
                    "metal-double"
                ]
            }
        }

        var label: String {
            switch self {
            case .phase1:
                return "Phase 1"
            case .phase2:
                return "Phase 2"
            }
        }
    }

    private let viewerVariants = [
        "baseline",
        "scalar-tight",
        "coord-precompute",
        "unsafe-buffer",
        "float-math",
        "parallel",
        "simd4-float",
        "metal",
        "metal-double"
    ]

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

                Button("Double Iterations") {
                    adjustMaxIterations(multiplier: 2.0)
                }
                .keyboardShortcut("+")
                .opacity(0)

                Button("Halve Iterations") {
                    adjustMaxIterations(multiplier: 0.5)
                }
                .keyboardShortcut("-")
                .opacity(0)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(Color.black)
            .highPriorityGesture(doubleTapGesture(in: proxy.size))
            .highPriorityGesture(quadTapGesture(in: proxy.size))
            .highPriorityGesture(shiftDragGesture(in: proxy.size))
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
            .simultaneousGesture(zoomGesture(in: proxy.size))
            .onChange(of: activeMode) { _, newMode in
                if newMode == .benchmark, !hasRunBenchmarks {
                    ensureBenchmarkRows()
                    Task {
                        await runBenchmarks()
                    }
                }
            }
            .onChange(of: benchmarkPhase) { _, _ in
                hasRunBenchmarks = false
                benchmarkRows = initialBenchmarkRows()
                if activeMode == .benchmark {
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
        KeyCaptureView(
            onTab: {
                toggleMode()
            },
            onIncrement: {
                adjustMaxIterations(multiplier: 2.0)
            },
            onDecrement: {
                adjustMaxIterations(multiplier: 0.5)
            }
        )
        #else
        EmptyView()
        #endif
    }

    private var viewerPane: some View {
        return ZStack {
            if let renderedImage {
                Image(decorative: renderedImage, scale: displayScale)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFill()
                    .scaleEffect(previewMagnification * gestureMagnification, anchor: zoomAnchor)
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
            if let selectionRect {
                Rectangle()
                    .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .frame(width: selectionRect.width, height: selectionRect.height)
                    .position(x: selectionRect.midX, y: selectionRect.midY)
            }
        }
    }

    private var benchmarkPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Benchmark Mode")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Spacer()
                    Picker("Phase", selection: $benchmarkPhase) {
                        Text(BenchmarkPhase.phase1.label).tag(BenchmarkPhase.phase1)
                        Text(BenchmarkPhase.phase2.label).tag(BenchmarkPhase.phase2)
                    }
                    .pickerStyle(.menu)
                    .tint(.white)
                }
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
            if activeMode == .viewer, progress < 1.0, showRenderProgress {
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
                rendererPicker
            } else {
                Text("Benchmark mode")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
            }
            Text("Iterations \(maxIterations)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(12)
        .background(.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(16)
    }

    private var zoomAnchor: UnitPoint {
#if os(iOS)
        return gestureZoomAnchor
#else
        return .center
#endif
    }

    @ViewBuilder private var rendererPicker: some View {
#if os(macOS)
        Menu {
            ForEach(viewerVariants, id: \.self) { variant in
                Button(variant) {
                    renderVariant = variant
                    renderToken += 1
                }
            }
        } label: {
            Text("Renderer \(renderVariant)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize()
        }
        .fixedSize()
#else
        Text("Renderer \(renderVariant)")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.9))
#endif
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

    private func applyZoom(magnification: CGFloat, anchor: UnitPoint, in size: CGSize) {
        let baseSpan = 3.0
        let realSpan = baseSpan / scale
        let imagSpan = realSpan * Double(size.height / max(1, size.width))
        let dx = Double(anchor.x - 0.5)
        let dy = Double(0.5 - anchor.y)

        let anchorReal = center.x + dx * realSpan
        let anchorImag = center.y + dy * imagSpan

        let newScale = scale * Double(magnification)
        let newRealSpan = baseSpan / newScale
        let newImagSpan = newRealSpan * Double(size.height / max(1, size.width))

        center.x = anchorReal - dx * newRealSpan
        center.y = anchorImag - dy * newImagSpan
        scale = newScale
        previewMagnification *= magnification
        renderToken += 1
    }

    private func shiftDragGesture(in size: CGSize) -> some Gesture {
        #if os(macOS)
        if #available(macOS 13.0, *) {
            return DragGesture(minimumDistance: 0)
                .modifiers(.shift)
                .onChanged { value in
                    if selectionStart == nil {
                        selectionStart = value.startLocation
                    }
                    selectionEnd = value.location
                }
                .onEnded { _ in
                    if let selectionRect {
                        applySelectionZoom(rect: selectionRect, in: size)
                    }
                    selectionStart = nil
                    selectionEnd = nil
                }
        } else {
            return DragGesture(minimumDistance: 0)
        }
        #else
        return DragGesture(minimumDistance: 0)
        #endif
    }

    private var selectionRect: CGRect? {
        guard let start = selectionStart, let end = selectionEnd else { return nil }
        let x = min(start.x, end.x)
        let y = min(start.y, end.y)
        let width = max(1, abs(end.x - start.x))
        let height = max(1, abs(end.y - start.y))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func applySelectionZoom(rect: CGRect, in size: CGSize) {
        let baseSpan = 3.0
        let realSpan = baseSpan / scale
        let imagSpan = realSpan * Double(size.height / max(1, size.width))

        let factorX = Double(rect.width / max(1, size.width))
        let factorY = Double(rect.height / max(1, size.height))
        let factor = max(factorX, factorY)
        guard factor > 0 else { return }

        let centerX = rect.midX
        let centerY = rect.midY
        let dx = Double(centerX / max(1, size.width) - 0.5)
        let dy = Double(0.5 - centerY / max(1, size.height))

        let anchorReal = center.x + dx * realSpan
        let anchorImag = center.y + dy * imagSpan

        let newScale = scale / factor
        let newRealSpan = baseSpan / newScale
        let newImagSpan = newRealSpan * Double(size.height / max(1, size.width))

        center.x = anchorReal - dx * newRealSpan
        center.y = anchorImag - dy * newImagSpan
        scale = newScale
        renderToken += 1
    }

    private func doubleTapGesture(in size: CGSize) -> some Gesture {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            return SpatialTapGesture(count: 2)
                .onEnded { value in
                    let leftZone = size.width * 0.25
                    let rightZone = size.width * 0.75
                    if value.location.x <= leftZone {
                        adjustMaxIterations(multiplier: 0.5)
                    } else if value.location.x >= rightZone {
                        adjustMaxIterations(multiplier: 2.0)
                    }
                }
        } else {
            return TapGesture(count: 2)
        }
        #else
        return TapGesture(count: 2)
        #endif
    }

    private func quadTapGesture(in size: CGSize) -> some Gesture {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            return SpatialTapGesture(count: 4)
                .onEnded { value in
                    let left = size.width * 0.25
                    let right = size.width * 0.75
                    if value.location.x > left && value.location.x < right {
                        toggleMode()
                    }
                }
        } else {
            return TapGesture(count: 4)
        }
        #else
        return TapGesture(count: 4)
        #endif
    }

    private func zoomGesture(in size: CGSize) -> some Gesture {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            return MagnifyGesture()
                .updating($gestureMagnification) { value, state, _ in
                    state = value.magnification
                }
                .updating($gestureZoomAnchor) { value, state, _ in
                    state = value.startAnchor
                }
                .onEnded { value in
                    applyZoom(magnification: value.magnification, anchor: value.startAnchor, in: size)
                }
        } else {
            return MagnificationGesture()
                .updating($gestureMagnification) { value, state, _ in
                    state = value
                }
                .onEnded { value in
                    scale *= Double(value)
                    previewMagnification *= value
                    renderToken += 1
                }
        }
        #else
        return MagnificationGesture()
            .updating($gestureMagnification) { value, state, _ in
                state = value
            }
            .onEnded { value in
                scale *= Double(value)
                previewMagnification *= value
                renderToken += 1
            }
        #endif
    }

    private func renderMandelbrot(size: CGSize, token: Int) async {
        guard activeMode == .viewer else { return }
        guard size.width > 0, size.height > 0 else { return }
        let pixelWidth = max(1, Int(size.width * displayScale))
        let pixelHeight = max(1, Int(size.height * displayScale))
        let center = center
        let scale = scale
        let configuration = MandelbrotConfiguration(maxIterations: maxIterations)
        let blockSizes = [64, 32, 16, 8, 4, 2, 1]
        let startTime = Date()

        await MainActor.run {
            progress = 0.0
            renderResolution = CGSize(width: pixelWidth, height: pixelHeight)
            showRenderProgress = false
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if progress < 1.0 {
                showRenderProgress = true
            }
        }

        let currentVariant = renderVariant
        let isMetalVariant = currentVariant == "metal" || currentVariant == "metal-double"
        for (index, blockSize) in blockSizes.enumerated() {
            if Task.isCancelled { return }
            let passWidth = isMetalVariant && blockSize > 1
                ? max(1, pixelWidth / blockSize)
                : pixelWidth
            let passHeight = isMetalVariant && blockSize > 1
                ? max(1, pixelHeight / blockSize)
                : pixelHeight

            let image = await RenderWorker.shared.renderImage(
                variant: currentVariant,
                width: passWidth,
                height: passHeight,
                center: center,
                scale: scale,
                blockSize: blockSize,
                configuration: configuration
            )

            await MainActor.run {
                guard token == renderToken else { return }
                if let image {
                    renderedImage = image
                    if token == renderToken, index == 0 {
                        previewOffset = .zero
                        previewMagnification = 1.0
                    }
                }
                progress = Double(index + 1) / Double(blockSizes.count)
            }
        }

        await MainActor.run {
            renderDuration = Date().timeIntervalSince(startTime)
            progress = 1.0
            showRenderProgress = false
        }
    }

    private func runBenchmarks() async {
        await MainActor.run {
            isBenchmarkRunning = true
            benchmarkRows = initialBenchmarkRows()
        }

        let variants = benchmarkPhase.variants

        var baselineRuns: [(Int, Int, Double)] = []
        var width = 128
        var height = 64
        while true {
            let seconds = await benchmarkVariant("baseline", width: width, height: height)
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
                let image = await RenderWorker.shared.renderImage(
                    variant: variant,
                    width: previewSize.0,
                    height: previewSize.1,
                    center: CGPoint(x: -0.5, y: 0.0),
                    scale: 1.0,
                    blockSize: 1
                )
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
                    variant: "baseline",
                    key: key,
                    seconds: seconds,
                    pixelsPerSecond: baselineRate
                )
            }
        }

        for (width, height) in selectedSizes {
            let key = "\(width)x\(height)"
            let pixels = Double(width * height)

            for variant in variants where variant != "baseline" {
                let seconds = await benchmarkVariant(variant, width: width, height: height)
                let rate = seconds > 0 ? pixels / seconds : 0
                await MainActor.run {
                    updateBenchmarkRow(
                        variant: variant,
                        key: key,
                        seconds: seconds,
                        pixelsPerSecond: rate
                    )
                }
            }
        }

        await MainActor.run {
            isBenchmarkRunning = false
            hasRunBenchmarks = true
        }
    }

    private func initialBenchmarkRows() -> [BenchmarkRow] {
        return benchmarkPhase.variants.map { BenchmarkRow(variant: $0, results: [:], previewImage: nil) }
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

    private func benchmarkVariant(_ variant: String, width: Int, height: Int) async -> Double {
        let start = Date()
        _ = await RenderWorker.shared.renderImage(
            variant: variant,
            width: width,
            height: height,
            center: CGPoint(x: -0.5, y: 0.0),
            scale: 1.0,
            blockSize: 1,
            configuration: MandelbrotConfiguration(maxIterations: maxIterations)
        )
        return Date().timeIntervalSince(start)
    }

    private func adjustMaxIterations(multiplier: Double) {
        let newValue = max(1, Int(Double(maxIterations) * multiplier))
        maxIterations = newValue
        renderToken += 1
        if activeMode == .benchmark {
            hasRunBenchmarks = false
            benchmarkRows = initialBenchmarkRows()
            Task {
                await runBenchmarks()
            }
        }
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
