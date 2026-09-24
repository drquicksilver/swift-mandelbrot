#if os(macOS)
  import Foundation
  import CoreGraphics
  import ImageIO
  import UniformTypeIdentifiers

  /// Runs before SwiftUI starts; full-image benchmarks and tiled exports share the product kernels.
  enum BenchmarkCLI {
    static let variants = RendererID.allCases.map(\.rawValue)

    static let help = """
      Usage: Mandelbrot --benchmark [options]
             Mandelbrot --render --output image.png [options]

      Runs without starting the GUI. Legacy timings include CPU colour conversion;
      GPU timings select kernel or completed coloured texture. Perturbation end-to-end
      timings also include CPU reference preparation. PNG writing is excluded.

        --variants LIST    Comma-separated renderers (default: baseline,parallel,metal)
                           Use 'all' for every renderer supported by the selected pipeline.
        --sizes LIST       Comma-separated WIDTHxHEIGHT (default: 1024x512,2048x1024)
        --iterations N     Iteration limit, 1...1000000 for GPU/tiles; legacy <=65535
        --runs N           Measured runs per renderer/size (default: 3)
        --warmup N         Untimed runs per renderer/size (default: 1; may be 0)
        --format FORMAT    markdown or json (default: markdown)
        --center-real X    Viewport center real coordinate (default: -0.5)
        --center-imag Y    Viewport center imaginary coordinate (default: 0)
        --scale Z         Zoom factor; horizontal span = 3/Z (default: 1).
                          Perturbation accepts decimal exponents through 2^13000.
        --renderer NAME   Single renderer for --render (default: metal)
        --size WxH        PNG resolution (default: 1024x1024)
        --output PATH     PNG destination (required for --render)
        --counts PATH     Optional raw UInt16 little-endian iteration counts,
                          row-major, top to bottom; only with --render
        --colouring MODE   smooth (GPU default) or legacy
        --palette NAME     blue-gold, fire, ice, ink, twilight, forest, orbit
        --density N        Iterations per palette cycle (default: 64)
        --offset N         Palette phase (default: 0)
        --samples PATH     Float32 samples (<=65535 iterations); -1 means capped
        --sample-records PATH  Raw little-endian UInt32 count + Float32 correction;
                          count 0xffffffff means capped; eight bytes per pixel
        --pipeline NAME    legacy, gpu or tiles (default: legacy); tiles exports PNGs
        --rotation DEG     View rotation in degrees; tile pipeline only
        --movie            Render a zoom movie to --output (.mov)
        --to LINK          Destination mandelbrot:// link for --movie
        --from LINK        Start link for --movie (default: the whole set)
        --duration S       Movie duration in seconds (default: 8)
        --fps N            Movie frame rate (default: 30)
        --cycles N         Palette cycles across the descent (default: 0)
        --ease on|off      Ease the movie in and out (default: on)
        --rebasing on|off  Critical-point rebasing; off is a recovery diagnostic
        --bla-radius MODE compound (default) or fixed (experimental error margin)
        --bla on|off|fixed Perturbation hierarchy, no skipping, or 32-step blocks
        --timing SCOPE     end-to-end or kernel (GPU benchmark only)
        --help             Show this help

      Renderers: \(variants.joined(separator: ", "))
      Reports median seconds and throughput; JSON also includes every sample.
      Exit status: 0 success, 1 rendering failure, 2 invalid arguments.
      """

    struct Options {
      var variants = ["baseline", "parallel", "metal"]
      var sizes = [(1024, 512), (2048, 1024)]
      var iterations = 200
      var runs = 3
      var warmup = 1
      var format = "markdown"
      var colouring = ColourSettings()
      var samples: String?
      var sampleRecords: String?
      var pipeline = "legacy"
      var timing = "end-to-end"
      var useBLA = true
      var hierarchicalBLA = true
      var fixedBLARadius = false
      var useRebasing = true
      var render = false
      var renderer = "metal"
      var size = (1024, 1024)
      var output: String?
      var counts: String?
      var centerReal = -0.5
      var centerImag = 0.0
      var scale = 1.0
      var realText = "-0.5", imagText = "0", scaleText = "1"
      var rotationDegrees = 0.0
      var movie = false
      var movieFrom: String?
      var movieTo: String?
      var movieSettings = MovieSettings(duration: 8, width: 1280, height: 720)
      var viewport = Viewport()
      var center: CGPoint { CGPoint(x: centerReal, y: centerImag) }

      init(arguments: [String]) throws {
        movie = arguments.contains("--movie")
        render = arguments.contains("--render")
        guard !(render && arguments.contains("--benchmark")) else {
          throw CLIError("Choose --render or --benchmark")
        }
        let renderFlags = ["--renderer", "--size", "--output", "--counts"]
        let benchmarkFlags = ["--variants", "--sizes", "--runs", "--warmup", "--format"]
        var index = 0
        while index < arguments.count {
          let flag = arguments[index]
          index += 1
          if flag == "--benchmark" || flag == "--render" || flag == "--movie" { continue }
          guard
            (renderFlags + benchmarkFlags + [
              "--iterations", "--center-real", "--center-imag", "--scale", "--pipeline", "--timing",
              "--rotation", "--to", "--from", "--duration", "--fps", "--cycles", "--ease",
              "--colouring", "--palette", "--density", "--offset", "--samples", "--sample-records",
              "--bla",
              "--rebasing", "--bla-radius",
            ]).contains(flag)
          else {
            throw CLIError("Unknown option: \(flag)")
          }
          // A movie takes the render flags it shares (--size, --output).
          let forbidden =
            movie
            ? benchmarkFlags + ["--renderer", "--counts"] : (render ? benchmarkFlags : renderFlags)
          guard !forbidden.contains(flag) else {
            throw CLIError("\(flag) is not available in this mode")
          }
          guard index < arguments.count else { throw CLIError("Missing value for \(flag)") }
          let value = arguments[index]
          index += 1
          switch flag {
          case "--rebasing":
            guard ["on", "off"].contains(value) else {
              throw CLIError("Rebasing must be on or off")
            }
            useRebasing = value == "on"
          case "--bla-radius":
            guard ["compound", "fixed"].contains(value) else {
              throw CLIError("BLA radius must be compound or fixed")
            }
            fixedBLARadius = value == "fixed"
          case "--bla":
            guard ["on", "off", "fixed"].contains(value) else {
              throw CLIError("BLA must be on, off or fixed")
            }
            useBLA = value != "off"
            hierarchicalBLA = value == "on"
          case "--colouring":
            guard ["legacy", "smooth"].contains(value) else {
              throw CLIError("Colouring must be legacy or smooth")
            }
            colouring.smooth = value == "smooth"
          case "--palette":
            guard let palette = Palette(rawValue: value) else { throw CLIError("Unknown palette") }
            colouring.palette = palette
          case "--density", "--offset":
            guard let number = Float(value), number.isFinite,
              flag == "--density" ? (1...4096).contains(number) : (-1000...1000).contains(number)
            else { throw CLIError("Invalid colour parameter") }
            if flag == "--density" { colouring.density = number } else { colouring.offset = number }
          case "--samples": samples = value
          case "--sample-records": sampleRecords = value
          case "--pipeline":
            guard ["legacy", "gpu", "tiles"].contains(value) else {
              throw CLIError("Pipeline must be legacy, gpu or tiles")
            }
            pipeline = value
          case "--rotation":
            guard let degrees = Double(value), degrees.isFinite, abs(degrees) <= 360 else {
              throw CLIError("Rotation must be degrees within [-360, 360]")
            }
            rotationDegrees = degrees
          case "--to", "--from":
            guard movie else { throw CLIError("\(flag) requires --movie") }
            if flag == "--to" { movieTo = value } else { movieFrom = value }
          case "--ease":
            guard ["on", "off"].contains(value) else { throw CLIError("Ease must be on or off") }
            movieSettings.eased = value == "on"
          case "--duration", "--cycles":
            guard let number = Double(value), number.isFinite, number >= 0 else {
              throw CLIError("\(flag) needs a number")
            }
            if flag == "--duration" {
              guard number > 0, number <= 600 else {
                throw CLIError("Duration must be in (0, 600]")
              }
              movieSettings.duration = number
            } else {
              guard number <= 64 else { throw CLIError("Cycles must be at most 64") }
              movieSettings.paletteCycles = number
            }
          case "--fps":
            guard let number = Int(value), (1...120).contains(number) else {
              throw CLIError("Frame rate must be in [1, 120]")
            }
            movieSettings.framesPerSecond = number
          case "--timing":
            guard ["end-to-end", "kernel"].contains(value) else {
              throw CLIError("Timing must be end-to-end or kernel")
            }
            timing = value
          case "--center-real", "--center-imag", "--scale":
            if flag == "--center-real" {
              realText = value
            } else if flag == "--center-imag" {
              imagText = value
            } else {
              scaleText = value
            }
          case "--renderer":
            guard BenchmarkCLI.variants.contains(value) else {
              throw CLIError("Unknown renderer: \(value)")
            }
            renderer = value
          case "--output", "--counts":
            guard !value.isEmpty else { throw CLIError("Empty path for \(flag)") }
            if flag == "--output" { output = value } else { counts = value }
          case "--variants":
            let names = value == "all" ? BenchmarkCLI.variants : value.components(separatedBy: ",")
            guard names.allSatisfy({ BenchmarkCLI.variants.contains($0) }) else {
              throw CLIError("Unknown renderer in: \(value)")
            }
            variants = names
          case "--sizes", "--size":
            let parsed = try value.components(separatedBy: ",").map { size in
              let parts = size.lowercased().components(separatedBy: "x")
              guard parts.count == 2,
                let width = Int(parts[0]), let height = Int(parts[1]),
                width > 0, height > 0, width <= 16384, height <= 16384,
                width * height <= 33_554_432
              else {
                throw CLIError(
                  "Invalid size: \(size) (maximum dimension 16384, maximum 33554432 pixels)")
              }
              return (width, height)
            }
            if flag == "--size" {
              guard parsed.count == 1 else { throw CLIError("--size needs one resolution") }
              size = parsed[0]
            } else {
              sizes = parsed
            }
          case "--format":
            guard ["markdown", "json"].contains(value) else {
              throw CLIError("Format must be markdown or json")
            }
            format = value
          default:
            guard let number = Int(value), number >= (flag == "--warmup" ? 0 : 1),
              number <= (flag == "--iterations" ? IterationPolicy.maximum : 1000)
            else {
              throw CLIError("Invalid value for \(flag): \(value)")
            }
            switch flag {
            case "--iterations": iterations = number
            case "--runs": runs = number
            default: warmup = number
            }
          }
        }
        viewport = try Viewport(real: realText, imag: imagText, zoom: scaleText)
        // Tiles stay axis-aligned in the plane, so only the compositor rotates.
        // The lab renderers sample axis-aligned rows and take no angle (2.14).
        if rotationDegrees != 0 {
          guard pipeline == "tiles" else {
            throw CLIError("--rotation requires --pipeline tiles")
          }
          viewport.angle = Viewport.normalised(rotationDegrees * .pi / 180)
        }
        centerReal = viewport.center.x
        centerImag = viewport.center.y
        scale = viewport.scale
        if pipeline == "legacy" && arguments.contains("all") {
          variants.removeAll { $0 == "perturbation" }
        }
        if pipeline != "legacy" && arguments.contains("all") {
          variants.removeAll {
            RendererID(rawValue: $0)?.isGPU != true
              || (viewport.logScale > log2(1e14) && $0 != "perturbation")
          }
        }
        let selected = render ? [renderer] : variants
        if selected.contains("perturbation") && (pipeline == "legacy" || !colouring.smooth) {
          throw CLIError("Perturbation requires --pipeline gpu or tiles with smooth colouring")
        }
        if viewport.logScale > log2(1e14) && selected.contains(where: { $0 != "perturbation" }) {
          throw CLIError("Scales beyond 1e14 require the perturbation renderer")
        }
        if iterations > 65535 && (pipeline == "legacy" || counts != nil || samples != nil) {
          throw CLIError(
            "Legacy rendering, --counts and --samples require iterations <=65535; use GPU/tiles and --sample-records for higher limits"
          )
        }
        if let path = sampleRecords {
          guard render, pipeline == "gpu", !path.isEmpty else {
            throw CLIError("--sample-records requires GPU PNG rendering")
          }
          if [output, counts, samples].compactMap({ $0 }).contains(where: {
            URL(fileURLWithPath: $0).standardizedFileURL
              == URL(fileURLWithPath: path).standardizedFileURL
          }) {
            throw CLIError("Output destinations must differ")
          }
        }
        if let samples {
          guard render, pipeline == "gpu", !samples.isEmpty else {
            throw CLIError("--samples requires GPU PNG rendering")
          }
          if [output, counts].compactMap({ $0 }).contains(where: {
            URL(fileURLWithPath: $0).standardizedFileURL
              == URL(fileURLWithPath: samples).standardizedFileURL
          }) {
            throw CLIError("Output destinations must differ")
          }
        }
        if pipeline == "gpu" && colouring.smooth && counts != nil {
          throw CLIError("Use --samples for smooth data, or --colouring legacy for integer counts")
        }
        if pipeline != "legacy"
          && !(render ? [renderer] : variants).allSatisfy({
            RendererID(rawValue: $0)?.isGPU == true
          })
        {
          throw CLIError("The GPU pipeline requires metal or metal-double renderers")
        }
        if timing == "kernel" && (pipeline != "gpu" || render) {
          throw CLIError("Kernel timing requires a GPU benchmark")
        }
        if pipeline == "tiles"
          && (!render || counts != nil || samples != nil || sampleRecords != nil)
        {
          throw CLIError(
            "Tile pipeline exports composited PNGs; use --render without --counts or --samples")
        }
        if pipeline == "tiles" {
          guard colouring.smooth else {
            throw CLIError("Tiles use smooth samples; use --pipeline gpu for legacy colouring")
          }
          let view = viewport
          guard scale >= 0.5,
            renderer == "perturbation" || scale <= view.maximumScale(pixelWidth: Double(size.0))
          else {
            throw CLIError("Tile scale is outside the viewer's FloatFloat precision range")
          }
        }
        if movie {
          guard !render, !arguments.contains("--benchmark") else {
            throw CLIError("Choose --movie, --render or --benchmark")
          }
          guard output != nil else { throw CLIError("--movie requires --output") }
          guard movieTo != nil else { throw CLIError("--movie requires --to") }
          let (width, height) = size
          movieSettings.width = width
          movieSettings.height = height
        }
        if render && output == nil { throw CLIError("--render requires --output") }
        if let output, let counts,
          URL(fileURLWithPath: output).standardizedFileURL
            == URL(fileURLWithPath: counts).standardizedFileURL
        {
          throw CLIError("PNG and counts destinations must differ")
        }
      }
    }

    struct CLIError: Error, CustomStringConvertible {
      let description: String
      init(_ description: String) { self.description = description }
    }

    struct Result: Encodable {
      let variant: String
      let width: Int
      let height: Int
      let samplesSeconds: [Double]
      var perturbation: [PerturbationMetrics]? = nil
      var medianSeconds: Double {
        let sorted = samplesSeconds.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
          ? (sorted[middle - 1] + sorted[middle]) / 2
          : sorted[middle]
      }
      var megapixelsPerSecond: Double { Double(width * height) / medianSeconds / 1_000_000 }

      enum CodingKeys: String, CodingKey {
        case variant, width, height, samplesSeconds, medianSeconds, megapixelsPerSecond,
          perturbation
      }
      func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(perturbation, forKey: .perturbation)
        try container.encode(variant, forKey: .variant)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(samplesSeconds, forKey: .samplesSeconds)
        try container.encode(medianSeconds, forKey: .medianSeconds)
        try container.encode(megapixelsPerSecond, forKey: .megapixelsPerSecond)
      }
    }

    struct Report: Encodable {
      let iterations: Int
      let runs: Int
      let warmup: Int
      let centerReal: Double
      let centerImag: Double
      let scale: Double?
      var timingScope = "iterations-and-colorization"
      var preciseCenterReal: String? = nil
      var preciseCenterImag: String? = nil
      var preciseScale: String? = nil
      let results: [Result]
    }

    static func run(arguments: [String]) async -> Int32 {
      if arguments.contains("--help") {
        print(help)
        return 0
      }
      let options: Options
      do {
        options = try Options(arguments: arguments)
      } catch {
        writeError("\(error). Use --help for usage.")
        return 2
      }

      if options.movie { return await renderMovie(options) }
      if options.pipeline == "tiles" { return await renderTiles(options) }
      if options.pipeline == "gpu" { return await runGPU(options) }
      if options.render { return await renderPNG(options) }
      var results: [Result] = []
      for (width, height) in options.sizes {
        for variant in options.variants {
          var samples: [Double] = []
          for run in 0..<(options.warmup + options.runs) {
            let start = DispatchTime.now().uptimeNanoseconds
            let image = await LabRenderer.shared.image(
              RendererID(rawValue: variant)!, width: width, height: height,
              center: options.center, scale: options.scale,
              configuration: MandelbrotConfiguration(maxIterations: options.iterations)
            )
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            guard image != nil else {
              writeError(
                "Renderer \(variant) failed at \(width)x\(height); check Metal availability for GPU variants."
              )
              return 1
            }
            if run >= options.warmup { samples.append(elapsed) }
          }
          results.append(
            Result(variant: variant, width: width, height: height, samplesSeconds: samples))
        }
      }
      if options.format == "json" {
        do {
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
          let data = try encoder.encode(
            Report(
              iterations: options.iterations, runs: options.runs,
              warmup: options.warmup, centerReal: options.centerReal,
              centerImag: options.centerImag, scale: options.scale, results: results))
          print(String(decoding: data, as: UTF8.self))
        } catch {
          writeError("Could not encode results: \(error)")
          return 1
        }
      } else {
        print("Center: (\(options.centerReal), \(options.centerImag)); scale: \(options.scale).")
        print(
          "Iterations: \(options.iterations); median of \(options.runs) runs; \(options.warmup) warmup runs. Includes colorization.\n"
        )
        print("| Variant | Resolution | Seconds | Mpx/s |")
        print("| --- | --- | ---: | ---: |")
        for result in results {
          let timing = String(
            format: "%.6f | %.2f", locale: Locale(identifier: "en_US_POSIX"),
            result.medianSeconds, result.megapixelsPerSecond)
          print("| \(result.variant) | \(result.width)x\(result.height) | \(timing) |")
        }
      }
      return 0
    }

    /// Zoom movies share the viewer's tile cache and compositor; the CLI exists
    /// so a movie can be rendered and inspected without the app's UI.
    @MainActor private static func renderMovie(_ options: Options) async -> Int32 {
      do {
        guard let destination = options.movieTo.flatMap({ URL(string: $0) }) else {
          throw CLIError("--to needs a mandelbrot:// link")
        }
        let end = try Location(url: destination)
        // Post-2.11 locations opt into a preplanned mapping schedule; old
        // links deliberately retain their fixed density and offset.
        var movieSettings = options.movieSettings
        movieSettings.automaticColour = end.automaticColour == true
        movieSettings.depthAdaptiveColour = end.automaticColour == false
        movieSettings.densityAdjustment = Float(end.densityAdjustment ?? 1)
        movieSettings.offsetAdjustment = Float(end.offsetAdjustment ?? 0)
        let start =
          try options.movieFrom.flatMap { URL(string: $0) }.map { try Location(url: $0) }
          ?? Location(real: "-0.5", imag: "0", scale: "1")
        let journey = try Journey.planned(
          start: start, end: end,
          aspectRatio: Double(options.movieSettings.width) / Double(options.movieSettings.height))
        let renderer = MovieRenderer()
        let url = URL(fileURLWithPath: options.output!)
        let began = ProcessInfo.processInfo.systemUptime
        _ = try await renderer.render(
          journey: journey, settings: movieSettings, colouring: end.colouring, to: url)
        // The movie's total iteration budget: the sum of its keyframes' limits,
        // which is what a depth policy for keyframes would have to move.
        let report: [String: Any] = [
          "frames": movieSettings.frameCount,
          "keyframes": renderer.counts.keyframes,
          "journey": journey.segments.map(\.kind.rawValue),
          "minimumDuration": journey.requestedDuration,
          "keyframeLimitSum": renderer.keyframeLimits.reduce(0) { $0 + $1.limit },
          "width": movieSettings.width, "height": movieSettings.height,
          "duration": movieSettings.duration,
          "startLog": try start.viewport().logScale, "endLog": try end.viewport().logScale,
          "seconds": ProcessInfo.processInfo.systemUptime - began,
          "output": url.path,
        ]
        print(
          String(
            decoding: try JSONSerialization.data(
              withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        return 0
      } catch {
        writeError(String(describing: error))
        return 2
      }
    }
    @MainActor private static func renderTiles(_ options: Options) async -> Int32 {
      do {
        guard let gpu = GPUContext.shared else { throw GPUFailure("GPU unavailable") }
        let view = options.viewport
        let size = options.size
        let store = TileStore()
        store.useBLA = options.useBLA
        store.hierarchicalBLA = options.hierarchicalBLA
        store.fixedBLARadius = options.fixedBLARadius
        store.update(
          viewport: view, size: CGSize(width: size.0, height: size.1), pixelWidth: Double(size.0),
          iterations: options.iterations,
          override: RendererID(rawValue: options.renderer), colouring: options.colouring)
        try await store.waitUntilReady()
        let texture = try await TileCompositor.snapshot(
          store: store, viewport: view, width: size.0, height: size.1,
          now: ProcessInfo.processInfo.systemUptime + TilePresentation.fadeDuration)
        let image = try await gpu.image(texture)
        let data = NSMutableData()
        guard
          let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil)
        else { throw GPUFailure("PNG encoder unavailable") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
          throw GPUFailure("PNG encoding failed")
        }
        try (data as Data).write(to: URL(fileURLWithPath: options.output!), options: .atomic)
        print(
          "Wrote \(options.output!) using the tile compositor (\(store.statistics.tiles) tiles)")
        return 0
      } catch {
        writeError(String(describing: error))
        return 1
      }
    }

    private static func runGPU(_ options: Options) async -> Int32 {
      guard let gpu = GPUContext.shared else {
        writeError("Metal is unavailable")
        return 1
      }
      do {
        if options.render {
          let (width, height) = options.size
          let frame = try await gpu.render(
            viewport: options.viewport,
            width: width, height: height, iterations: options.iterations,
            renderer: RendererID(rawValue: options.renderer)!, settings: options.colouring,
            useBLA: options.useBLA, useRebasing: options.useRebasing,
            hierarchicalBLA: options.hierarchicalBLA, fixedBLARadius: options.fixedBLARadius)
          let image = try await gpu.image(frame.colour)
          let data = NSMutableData()
          guard
            let destination = CGImageDestinationCreateWithData(
              data, UTType.png.identifier as CFString, 1, nil)
          else { throw CLIError("PNG encoder unavailable") }
          CGImageDestinationAddImage(destination, image, nil)
          guard CGImageDestinationFinalize(destination) else {
            throw CLIError("PNG encoding failed")
          }
          try (data as Data).write(to: URL(fileURLWithPath: options.output!), options: .atomic)
          if let path = options.sampleRecords {
            try await gpu.readback(frame.samples).write(
              to: URL(fileURLWithPath: path), options: .atomic)
          }
          if let path = options.samples {
            let data = try await gpu.readback(frame.samples)
            try SampleRecord.floatSamples(data).write(
              to: URL(fileURLWithPath: path), options: .atomic)
          }
          if let path = options.counts {
            let samples = try await gpu.readback(frame.samples)
            let raw = samples.withUnsafeBytes { buffer -> Data in
              var result = Data()
              for sample in buffer.bindMemory(to: SampleRecord.self) {
                let count =
                  sample.iteration >= SampleRecord.glitched
                  ? options.iterations : Int(sample.iteration)
                result.append(UInt8(count & 255))
                result.append(UInt8((count >> 8) & 255))
              }
              return result
            }
            try raw.write(to: URL(fileURLWithPath: path), options: .atomic)
          }
          print("Wrote \(options.output!) using GPU computation and colouring")
          return 0
        }
        var rows: [Result] = []
        for (width, height) in options.sizes {
          for variant in options.variants {
            var samples: [Double] = []
            var metrics: [PerturbationMetrics] = []
            for run in 0..<(options.runs + options.warmup) {
              let start = DispatchTime.now().uptimeNanoseconds
              let frame = try await gpu.render(
                viewport: options.viewport,
                width: width, height: height, iterations: options.iterations,
                renderer: RendererID(rawValue: variant)!, settings: options.colouring,
                useBLA: options.useBLA, useRebasing: options.useRebasing,
                hierarchicalBLA: options.hierarchicalBLA, fixedBLARadius: options.fixedBLARadius)
              let seconds =
                options.timing == "kernel"
                ? frame.kernelSeconds : Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
              if run >= options.warmup {
                samples.append(seconds)
                if let value = frame.perturbation { metrics.append(value) }
              }
            }
            rows.append(
              Result(
                variant: variant, width: width, height: height, samplesSeconds: samples,
                perturbation: metrics.isEmpty ? nil : metrics))
          }
        }
        let report = Report(
          iterations: options.iterations, runs: options.runs, warmup: options.warmup,
          centerReal: options.centerReal, centerImag: options.centerImag,
          scale: options.viewport.logScale > 1023 ? nil : options.scale,
          timingScope: options.timing == "kernel"
            ? "gpu-compute-only" : "gpu-compute-and-colour-no-readback",
          preciseCenterReal: options.realText, preciseCenterImag: options.imagText,
          preciseScale: options.scaleText, results: rows)
        if options.format == "json" {
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
          print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } else {
          print("GPU \(report.timingScope); median of \(options.runs) runs")
          print("| Renderer | Size | Seconds | Mpx/s |\n| --- | --- | ---: | ---: |")
          for row in rows {
            print(
              String(
                format: "| %@ | %dx%d | %.6f | %.2f |", row.variant, row.width, row.height,
                row.medianSeconds, row.megapixelsPerSecond))
          }
        }
        return 0
      } catch {
        writeError(String(describing: error))
        return 1
      }
    }

    private static func renderPNG(_ options: Options) async -> Int32 {
      let (width, height) = options.size
      guard
        let iterations = await LabRenderer.shared.iterations(
          RendererID(rawValue: options.renderer)!, width: width, height: height,
          center: options.center, scale: options.scale,
          configuration: MandelbrotConfiguration(maxIterations: options.iterations)
        ), let image = MandelbrotColorizer.image(from: iterations)
      else {
        writeError(
          "Renderer \(options.renderer) failed; check Metal availability for GPU variants.")
        return 1
      }
      // Encode to memory first, then atomically replace the destination.
      let data = NSMutableData()
      guard
        let destination = CGImageDestinationCreateWithData(
          data, UTType.png.identifier as CFString, 1, nil)
      else {
        writeError("Could not create PNG encoder")
        return 1
      }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else {
        writeError("Could not encode PNG")
        return 1
      }
      do {
        try (data as Data).write(to: URL(fileURLWithPath: options.output!), options: .atomic)
        if let counts = options.counts {
          var raw = Data(capacity: width * height * 2)
          for y in 0..<height {
            for x in 0..<width {
              let value = iterations.value(atX: x, y: y)
              raw.append(UInt8(value & 255))
              raw.append(UInt8((value >> 8) & 255))
            }
          }
          try raw.write(to: URL(fileURLWithPath: counts), options: .atomic)
        }
      } catch {
        writeError("Could not write render output: \(error)")
        return 1
      }
      print(
        "Wrote \(options.output!) (\(width)x\(height), \(options.renderer), center \(options.centerReal),\(options.centerImag), scale \(options.scale), iterations \(options.iterations))"
      )
      return 0
    }

    private static func writeError(_ message: String) {
      FileHandle.standardError.write(Data((message + "\n").utf8))
    }
  }
#endif
