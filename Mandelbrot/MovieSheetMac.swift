#if os(macOS)
  import AVKit
  import SwiftUI

  /// The Mac movie sheet, forked from the iOS `MovieView` so each platform can
  /// have the shape that suits it: a dialog here, a grouped form there.
  ///
  /// One dialog, three states.  A render dims the settings it came from rather
  /// than replacing them, so the movie being made stays legible beside its own
  /// progress, and the finished movie arrives underneath them.

  /// What the sheet is showing.
  enum MoviePhase {
    case settings
    case rendering
    case complete(MovieOutcome)
  }

  /// The facts about a finished movie, every one of them measured rather than
  /// estimated: the file is on disk by the time this is made.
  struct MovieOutcome: Equatable {
    var url: URL
    var path: String
    var frames: Int
    var seconds: Int
    var size: String
  }

  struct MovieSheetMac: View {
    @ObservedObject var model: ExplorerModel
    /// The renderer publishes progress, the stage, completion and the finished
    /// file, and the model does not republish what it says, so the sheet
    /// observes it directly.
    @ObservedObject private var movies: MovieRenderer
    @ObservedObject private var library = MovieLibrary.shared
    @StateObject private var fromImage = LocationThumbnail()
    @StateObject private var toImage = LocationThumbnail()
    @Environment(\.dismiss) private var dismiss
    @State private var startChoice: UUID?
    @State private var settings = MovieSettings()
    @State private var outcome: MovieOutcome?
    @State private var problem: String?
    @State private var player: AVPlayer?
    @State private var explaining = false

    /// `movies` and `outcome` are the seams the previews pose a state through;
    /// the app passes neither.
    init(model: ExplorerModel, movies: MovieRenderer? = nil, outcome: MovieOutcome? = nil) {
      _model = ObservedObject(wrappedValue: model)
      _movies = ObservedObject(wrappedValue: movies ?? model.movies)
      _outcome = State(initialValue: outcome)
    }

    // MARK: The journey

    private var places: [Location] { Location.gallery + model.bookmarks.bookmarks }
    private var start: Location {
      places.first { $0.id == startChoice } ?? Location.gallery[0]
    }
    private var end: Location { model.location }
    private var path: ZoomPath? {
      try? ZoomPath(start: start, end: end, eased: settings.eased)
    }
    private var phase: MoviePhase {
      if movies.isRendering { return .rendering }
      if let outcome { return .complete(outcome) }
      return .settings
    }
    private var isRendering: Bool {
      if case .rendering = phase { return true }
      return false
    }

    var body: some View {
      VStack(spacing: 0) {
        header
        VStack(alignment: .leading, spacing: 18) {
          section("Journey") { journeyCard }
          section("Movie Settings") { settingsCard }
          section("Output") { outputCard }
          if case .complete(let outcome) = phase { completionCard(outcome) }
        }
        .disabled(isRendering)
        // A render dims what it is rendering from, so the settings stay
        // readable without looking live.
        .opacity(isRendering ? 0.45 : 1)
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
        Divider()
        footer
      }
      .frame(width: 620)
      .background(Color(nsColor: .windowBackgroundColor))
      .onAppear { startChoice = startChoice ?? Location.gallery[0].id }
      .task(id: LocationThumbnail.key(start)) {
        await fromImage.render(start, width: 232, height: 140)
      }
      .task(id: LocationThumbnail.key(end)) {
        await toImage.render(end, width: 232, height: 140)
      }
      .onChange(of: movies.output) { _, url in adopt(url) }
      .onDisappear {
        player?.pause()
        fromImage.release()
        toImage.release()
      }
    }

    private var header: some View {
      VStack(spacing: 4) {
        Text("Create Zoom Movie").font(.title2.bold())
        Text("Render an animated journey between two views of the Mandelbrot set.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .multilineTextAlignment(.center)
      .padding(.top, 22)
      .padding(.bottom, 18)
    }

    private func section<Content: View>(
      _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.headline)
        content()
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
      }
    }

    // MARK: Journey

    private var journeyCard: some View {
      HStack(spacing: 14) {
        thumbnail(fromImage, caption: start.name.isEmpty ? "Starting place" : start.name)
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 8) {
            Text("From:").frame(width: 52, alignment: .trailing)
            Picker("", selection: $startChoice) {
              ForEach(places) { place in
                Text(place.name.isEmpty ? "\(place.scale)×" : place.name).tag(place.id as UUID?)
              }
            }
            .labelsHidden()
          }
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("To:").frame(width: 52, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
              Text("Current view (\(MovieSheetMac.zoom(end)))")
              Text(
                path == nil
                  ? "Zoom in further than the starting place."
                  : "Zooms in from the starting place."
              )
              .font(.caption)
              .foregroundStyle(path == nil ? Color.orange : Color.secondary)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        thumbnail(toImage, caption: "Current view")
      }
    }

    private func thumbnail(_ source: LocationThumbnail, caption: String) -> some View {
      VStack(spacing: 6) {
        RoundedRectangle(cornerRadius: 6)
          .fill(Color.black.opacity(0.85))
          .frame(width: 116, height: 70)
          .overlay {
            if let image = source.image {
              Image(image, scale: 2, label: Text(caption))
                .resizable()
                .scaledToFill()
            } else if source.isRendering {
              ProgressView().controlSize(.small)
            }
          }
          .clipShape(RoundedRectangle(cornerRadius: 6))
        Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      .frame(width: 116)
    }

    // MARK: Settings

    private var settingsCard: some View {
      HStack(alignment: .top, spacing: 16) {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
          GridRow {
            Text("Resolution:").gridColumnAlignment(.trailing)
            Picker("", selection: resolution) {
              ForEach(MovieSettings.resolutions, id: \.name) { option in
                Text(verbatim: "\(option.name) (\(option.width) × \(option.height))")
                  .tag(option.name)
              }
            }
            .labelsHidden()
            .frame(width: 180)
          }
          GridRow {
            Text("Duration:").gridColumnAlignment(.trailing)
            HStack(spacing: 6) {
              TextField("", value: duration, format: .number).frame(width: 56)
              Text("seconds").foregroundStyle(.secondary)
            }
          }
          GridRow {
            Text("Frame rate:").gridColumnAlignment(.trailing)
            Picker("", selection: $settings.framesPerSecond) {
              Text("24 fps").tag(24)
              Text("30 fps").tag(30)
              Text("60 fps").tag(60)
            }
            .labelsHidden()
          }
          GridRow {
            Text("Palette cycles:").gridColumnAlignment(.trailing)
            HStack(spacing: 6) {
              TextField("", value: cycles, format: .number).frame(width: 56)
              Stepper("", value: cycles, in: 0...16).labelsHidden()
            }
          }
          GridRow {
            Color.clear.frame(height: 0)
            Toggle("Ease in and out", isOn: $settings.eased)
          }
        }
        Divider()
        statistics
      }
    }

    /// Only what is known rather than guessed.  Keyframes are the whole cost of
    /// a render -- one full render per zoom level, with the frames between them
    /// resampled from the pair on either side -- so the count stands here in
    /// place of a render-time estimate we have no way to make.
    private var statistics: some View {
      VStack(alignment: .leading, spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text("\(settings.frameCount) frames")
          Text(verbatim: "\(settings.width) × \(settings.height)").foregroundStyle(.secondary)
        }
        Divider()
        VStack(alignment: .leading, spacing: 2) {
          Text("Zoom range").font(.caption).foregroundStyle(.secondary)
          Text("\(MovieSheetMac.zoom(start)) → \(MovieSheetMac.zoom(end))")
        }
        VStack(alignment: .leading, spacing: 2) {
          Text("Keyframes").font(.caption).foregroundStyle(.secondary)
          Text(path.map { "\($0.keyframeLevels.count)" } ?? "—")
        }
      }
      .font(.callout)
      .frame(width: 150, alignment: .leading)
    }

    /// A zoom to read rather than parse: plain digits up to ten billion, an
    /// exponent past that, where the digits stop meaning anything.
    static func zoom(_ location: Location) -> String {
      guard let view = try? location.viewport() else { return location.scale }
      if view.logScale < 33 {
        return pow(2, view.logScale).formatted(.number.precision(.fractionLength(0))) + "×"
      }
      let decimal = view.logScale / log2(10)
      let exponent = Int(floor(decimal))
      let mantissa = pow(10, decimal - Double(exponent))
      return "\(mantissa.formatted(.number.precision(.fractionLength(1))))e\(exponent)×"
    }

    // MARK: Output

    private var outputCard: some View {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Text("Save to:")
          TextField("", text: .constant(abbreviated(library.folder))).disabled(true)
          Button("Choose…") { library.choose() }
        }
        if case .complete = phase {
        } else {
          Text("The movie will be saved as a QuickTime .mov file.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 62)
        }
      }
    }

    /// The account's own home, not `homeDirectoryForCurrentUser`, which is a
    /// container when the process is sandboxed -- as a preview's is -- and then
    /// abbreviates nothing.
    private static let home: String = {
      if let directory = getpwuid(getuid())?.pointee.pw_dir {
        return String(cString: directory)
      }
      return FileManager.default.homeDirectoryForCurrentUser.path
    }()

    private func abbreviated(_ url: URL) -> String {
      let path = url.path
      guard path.hasPrefix(Self.home) else { return path }
      return "~" + path.dropFirst(Self.home.count)
    }

    // MARK: Finished

    private func completionCard(_ outcome: MovieOutcome) -> some View {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "checkmark.circle.fill")
          .font(.title2)
          .foregroundStyle(.white, .green)
        VStack(alignment: .leading, spacing: 4) {
          Text("Render complete").font(.headline)
          Text("Movie saved to \(outcome.path)").font(.callout)
          Text("\(outcome.frames) frames · \(outcome.seconds) seconds · \(outcome.size)")
            .font(.caption)
            .foregroundStyle(.secondary)
          HStack(spacing: 8) {
            Button("Reveal in Finder") { library.reveal(outcome.url) }
            ShareLink(item: outcome.url) { Label("Share…", systemImage: "square.and.arrow.up") }
          }
          .padding(.top, 4)
        }
        Spacer(minLength: 0)
        VideoPlayer(player: player)
          .frame(width: 160, height: 96)
          .clipShape(RoundedRectangle(cornerRadius: 6))
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
      switch phase {
      case .rendering:
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text(headline).font(.headline)
            Spacer()
            Text("\(Int((movies.progress * 100).rounded()))%").foregroundStyle(.secondary)
          }
          ProgressView(value: movies.progress)
          HStack {
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { movies.cancel() }
          }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
      case .settings, .complete:
        VStack(alignment: .leading, spacing: 8) {
          if let error = movies.error ?? problem {
            Text(error).font(.caption).foregroundStyle(.red)
          }
          HStack {
            Button {
              explaining.toggle()
            } label: {
              Image(systemName: "questionmark")
            }
            .buttonStyle(.bordered)
            .clipShape(Circle())
            .help("About zoom movies")
            .popover(isPresented: $explaining, arrowEdge: .top) { explanation }
            Spacer()
            if case .complete = phase {
              Button("Close") { dismiss() }
              Button("Render Another Movie") { reset() }.buttonStyle(.borderedProminent)
            } else {
              Button("Cancel") { dismiss() }
              Button("Render Movie") { render() }
                .buttonStyle(.borderedProminent)
                .disabled(path == nil)
            }
          }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
      }
    }

    /// The headline is whatever the render is doing now, and the quieter line
    /// the counter it is not on: a frame waits on the keyframe being rendered,
    /// and a keyframe is what the frames after it are drawn from.
    private var headline: String {
      let counts = movies.counts
      if counts.onKeyframe || counts.frames == 0 {
        return counts.keyframes == 0
          ? "Preparing…" : "Rendering keyframe \(counts.keyframe) of \(counts.keyframes)"
      }
      return "Rendering frame \(counts.frame) of \(counts.frames)"
    }
    private var detail: String {
      let counts = movies.counts
      if counts.onKeyframe || counts.frames == 0 {
        return counts.frame == 0 ? "" : "Frame \(counts.frame) of \(counts.frames)"
      }
      return counts.keyframes == 0 ? "" : "Keyframe \(counts.keyframe) of \(counts.keyframes)"
    }

    private var explanation: some View {
      VStack(alignment: .leading, spacing: 8) {
        Text("Zoom movies").font(.headline)
        Text(
          "The movie descends from the starting place to the view behind this sheet, holding "
            + "the destination still while everything else flows outward.")
        Text(
          "A keyframe is a full render, one per zoom level of the descent, and the frames "
            + "between them are blended from the pair on either side. The keyframe count is "
            + "what a render spends its time on.")
        Text("Cancelling stops the render. A finished movie stays where it was saved.")
      }
      .font(.callout)
      .frame(width: 320, alignment: .leading)
      .padding(14)
    }

    // MARK: Doing it

    private var resolution: Binding<String> {
      Binding(
        get: { MovieSettings.resolutions.first { $0.width == settings.width }?.name ?? "1080p" },
        set: { name in
          guard let option = MovieSettings.resolutions.first(where: { $0.name == name })
          else { return }
          settings.width = option.width
          settings.height = option.height
        })
    }
    private var duration: Binding<Int> {
      Binding(
        get: { Int(settings.duration) },
        set: { settings.duration = Double(max(2, min(120, $0))) })
    }
    private var cycles: Binding<Int> {
      Binding(
        get: { Int(settings.paletteCycles) },
        set: { settings.paletteCycles = Double(max(0, min(16, $0))) })
    }

    private func render() {
      problem = nil
      outcome = nil
      movies.output = nil
      do {
        let path = try ZoomPath(start: start, end: end, eased: settings.eased)
        // Nothing behind the sheet is on screen, and a render wants the GPU and
        // the memory: stop the viewer's cache competing for both.  The
        // compositor resumes it on the first frame after the sheet closes.
        model.tiles.cancel()
        movies.start(
          path: path, settings: settings, colouring: model.colouring,
          to: library.destination(named: MovieNaming.fileName()))
      } catch {
        problem = String(describing: error)
      }
    }

    /// Back to the settings, keeping them; the finished movie stays on disk.
    private func reset() {
      player?.pause()
      player = nil
      outcome = nil
      movies.output = nil
      movies.error = nil
      problem = nil
    }

    /// What a finished render leaves behind, measured off the file itself.
    private func adopt(_ url: URL?) {
      player?.pause()
      guard let url else {
        player = nil
        outcome = nil
        return
      }
      player = AVPlayer(url: url)
      let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
      outcome = MovieOutcome(
        url: url, path: abbreviated(url), frames: settings.frameCount,
        seconds: Int(settings.duration),
        size: bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")
    }
  }

  #if DEBUG
    @MainActor private func previewModel() -> ExplorerModel {
      let model = ExplorerModel()
      model.apply(Location.gallery[1], record: false)
      return model
    }

    #Preview("Settings") {
      MovieSheetMac(model: previewModel(), movies: .posed())
    }

    #Preview("Rendering") {
      MovieSheetMac(
        model: previewModel(),
        movies: .posed(
          progress: 0.39, stage: "Frame 142 of 360",
          counts: MovieCounts(frame: 142, frames: 360, keyframe: 6, keyframes: 13)))
    }

    #Preview("Complete") {
      MovieSheetMac(
        model: previewModel(), movies: .posed(),
        outcome: MovieOutcome(
          url: URL(fileURLWithPath: "/tmp/Mandelbrot zoom.mov"),
          path: "~/Movies/Mandelbrot zoom 2026-09-18-175406.mov",
          frames: 360, seconds: 12, size: "24.3 MB"))
    }
  #endif
#endif
