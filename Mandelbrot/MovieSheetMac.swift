#if os(macOS)
  import AppKit
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
    @StateObject private var preview = JourneyPreviewRenderer()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let completion = "completion"
    @State private var startChoice: UUID?
    @State private var settings = MovieSettings()
    @State private var outcome: MovieOutcome?
    @State private var problem: String?
    @State private var player: AVPlayer?
    @State private var explaining = false
    @State private var journey: Journey?
    @State private var journeyProblem: String?
    @State private var editingJourney = false
    @State private var previewExpanded = true
    @State private var suggestedOverviewLog: Double?
    @State private var maximumSheetHeight = MovieSheetSizePolicy.initialMaximumHeight

    /// `movies`, `outcome` and `startingAt` are seams the previews pose a state
    /// through; the app passes none of them.
    init(
      model: ExplorerModel, movies: MovieRenderer? = nil, outcome: MovieOutcome? = nil,
      startingAt: Location? = nil
    ) {
      _model = ObservedObject(wrappedValue: model)
      _movies = ObservedObject(wrappedValue: movies ?? model.movies)
      _outcome = State(initialValue: outcome)
      // Never nil: an unmatched selection leaves the From popup blank.
      _startChoice = State(initialValue: (startingAt ?? Location.gallery[0]).id)
    }

    // MARK: The journey

    private var places: [Location] { Location.gallery + model.bookmarks.bookmarks }
    private var start: Location {
      places.first { $0.id == startChoice } ?? Location.gallery[0]
    }
    private var end: Location { model.location }
    private var requiredDuration: Double { journey?.requestedDuration ?? 0 }
    private var movieSettings: MovieSettings {
      var result = settings
      result.automaticColour = model.colourSnapshotPinned
      result.depthAdaptiveColour = model.isDepthColouring
      result.densityAdjustment = model.densityAdjustment
      result.offsetAdjustment = model.offsetAdjustment
      return result
    }
    private var durationIsTooShort: Bool {
      journey != nil && settings.duration + 0.001 < requiredDuration
    }
    private var previewKey: String {
      guard let journey, !isRendering, outcome == nil else { return "no-preview" }
      let segments = journey.segments.map {
        "\($0.kind.rawValue)|\(LocationThumbnail.key($0.from))|\(LocationThumbnail.key($0.to))"
          + "|\($0.duration)|\($0.holdDuration)"
      }
      return segments.joined(separator: ";") + "|\(settings.duration)|\(settings.eased)"
        + "|\(settings.paletteCycles)|\(model.colourSnapshotPinned)|\(model.densityAdjustment)"
        + "|\(model.offsetAdjustment)|\(model.colouring.density)|\(model.colouring.offset)"
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
        ScrollViewReader { scroller in
          ScrollView {
            VStack(alignment: .leading, spacing: 18) {
              section("Journey") { journeyCard }
              section("Movie Settings") { settingsCard }
              section("Output") { outputCard }
              if case .complete(let outcome) = phase {
                completionCard(outcome).id(Self.completion)
              }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
          }
          // The finished movie arrives below everything it was made from, so
          // the sheet brings it into view rather than leaving it off the end.
          .onChange(of: outcome) { _, finished in
            guard finished != nil else { return }
            withAnimation(reduceMotion ? nil : .default) {
              scroller.scrollTo(Self.completion, anchor: .bottom)
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(isRendering)
        // A render dims what it is rendering from, so the settings stay
        // readable without looking live.
        .opacity(isRendering ? 0.45 : 1)
        Divider()
        footer
      }
      .frame(
        minWidth: 600, idealWidth: 620, maxWidth: 680,
        minHeight: MovieSheetSizePolicy.minimumContentHeight,
        idealHeight: maximumSheetHeight,
        maxHeight: maximumSheetHeight
      )
      .background(Color(nsColor: .windowBackgroundColor))
      .background(MovieSheetSizePolicy(maximumHeight: $maximumSheetHeight))
      .onAppear {
        refreshJourney()
      }
      .onChange(of: startChoice) { _, _ in refreshJourney() }
      .task(id: LocationThumbnail.key(start)) {
        await fromImage.render(start, width: 232, height: 140)
      }
      .task(id: LocationThumbnail.key(end)) {
        await toImage.render(end, width: 232, height: 140)
      }
      .task(id: previewKey) {
        guard let journey, !isRendering, outcome == nil else {
          preview.cancel()
          return
        }
        preview.start(journey: journey, settings: movieSettings, colouring: model.colouring)
      }
      .onChange(of: movies.output) { _, url in adopt(url) }
      .onDisappear {
        player?.pause()
        fromImage.release()
        toImage.release()
        preview.cancel()
      }
    }

    private var header: some View {
      VStack(spacing: 4) {
        Text("Render a Zoom Movie").font(.title2.bold())
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
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 14) {
          thumbnail(
            fromImage,
            caption: start.name.isEmpty ? String(localized: "Starting place") : start.name)
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
              Text("From:").frame(width: 52, alignment: .trailing)
              Picker("", selection: $startChoice) {
                PlaceChoices(bookmarks: model.bookmarks.bookmarks)
              }
              .labelsHidden()
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text("To:").frame(width: 52, alignment: .trailing)
              Text("This view (\(end.zoomDescription))")
            }
            if let journey {
              Text(journey.description())
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else if let journeyProblem {
              Text(journeyProblem).font(.caption).foregroundStyle(.orange)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          thumbnail(toImage, caption: String(localized: "This view"))
        }
        // The preview is for choosing; once a render starts it would be an
        // empty box under a stale caption, so it steps aside.
        if journey != nil, case .settings = phase {
          DisclosureGroup("Journey Preview", isExpanded: $previewExpanded) {
            journeyPreview
          }
          .font(.callout)
        }
        if let journey, !journey.isDirectDescent {
          DisclosureGroup("Edit Journey", isExpanded: $editingJourney) {
            timeline(journey)
          }
          .font(.callout)
        }
      }
    }

    private var journeyPreview: some View {
      VStack(alignment: .leading, spacing: 7) {
        HStack {
          Spacer()
          Text("480 × 270 · 12 fps")
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        ZStack {
          RoundedRectangle(cornerRadius: 8).fill(.black)
          if let player = preview.player {
            VideoPlayer(player: player)
          } else {
            VStack(spacing: 8) {
              if preview.isRendering { ProgressView().controlSize(.small) }
              Text(preview.isRendering ? "Preparing preview movie…" : "Preview unavailable")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        if let error = preview.error {
          Text(error).font(.caption).foregroundStyle(.red)
        } else {
          Text("Play, pause and scrub this low-resolution version of the exact journey.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }

    private func timeline(_ route: Journey) -> some View {
      VStack(alignment: .leading, spacing: 8) {
        if let suggestedOverviewLog, overviewLog(route) != nil {
          VStack(alignment: .leading, spacing: 4) {
            ValueSlider(
              "Overview", value: overviewScale,
              in: (suggestedOverviewLog - 4)...suggestedOverviewLog,
              format: overviewScaleDescription
            )
            .font(.callout)
            Text(
              "Pull back for more context; the right end is the closest overview that keeps both places in view."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          .padding(8)
          .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
        }
        ForEach(Array(route.segments.indices), id: \.self) { index in
          let segment = route.segments[index]
          HStack(spacing: 10) {
            Image(systemName: segment.kind == .zoom ? "magnifyingglass" : "arrow.left.and.right")
              .frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
              Text(route.title(of: segment)).font(.callout.weight(.medium))
              Text("At least \(seconds(segment.minimum))")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ValueStepper(
              "Duration", value: segmentDuration(index), in: segment.minimum...120, unit: "s"
            )
            .labelsHidden()
          }
          .padding(8)
          .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
        }
        HStack {
          Button("Add hold") { addHold() }
          Button("Reset suggested journey") { refreshJourney() }
          Spacer()
          Text("The timeline cannot make a camera move faster than its safe pace.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .padding(.top, 6)
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
            ValueStepper("Duration", value: duration, in: 2...120, unit: "seconds")
              .labelsHidden()
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
            ValueStepper("Palette cycles", value: $settings.paletteCycles, in: 0...16)
              .labelsHidden()
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

    private var statistics: some View {
      VStack(alignment: .leading, spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text("\(settings.frameCount) frames")
          Text(verbatim: "\(settings.width) × \(settings.height)").foregroundStyle(.secondary)
        }
        Divider()
        VStack(alignment: .leading, spacing: 2) {
          Text("Journey").font(.caption).foregroundStyle(.secondary)
          Text(journey?.summary ?? "—")
        }
        VStack(alignment: .leading, spacing: 2) {
          Text("Minimum smooth duration").font(.caption).foregroundStyle(.secondary)
          Text(journey.map { seconds($0.minimumDuration) } ?? "—")
        }
        if let journey, journey.requestedDuration > journey.minimumDuration + 0.001 {
          VStack(alignment: .leading, spacing: 2) {
            Text("Edited journey length").font(.caption).foregroundStyle(.secondary)
            Text(seconds(journey.requestedDuration))
          }
        }
        VStack(alignment: .leading, spacing: 2) {
          Text("Estimated file size").font(.caption).foregroundStyle(.secondary)
          Text(estimatedFileSize)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text("Estimated render time").font(.caption).foregroundStyle(.secondary)
          Text(estimatedRenderTime)
        }
      }
      .font(.callout)
      .frame(width: 150, alignment: .leading)
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

    /// Shown resolved, because the sandbox's own `Movies` is a symlink out to
    /// the real one: the container path names a folder nobody would go looking
    /// in, and the file lands in `~/Movies`.
    private func abbreviated(_ url: URL) -> String {
      let path = url.resolvingSymlinksInPath().path
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
            if let left = movies.timeRemaining {
              Text("· \(left)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { movies.cancel() }
          }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
      case .settings, .complete:
        VStack(alignment: .leading, spacing: 8) {
          if durationIsTooShort {
            HStack(spacing: 6) {
              Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
              Text(
                "This journey needs at least \(seconds(requiredDuration)) for a smooth camera move."
              )
              .font(.caption).foregroundStyle(.secondary)
              Button("Use \(seconds(requiredDuration))") {
                settings.duration = ceil(requiredDuration)
              }
              .font(.caption)
            }
          }
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
              Button(movies.error == nil ? "Render Movie" : "Try Again") { render() }
                .buttonStyle(.borderedProminent)
                .disabled(journey == nil || durationIsTooShort)
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
          ? String(localized: "Preparing…")
          : String(localized: "Rendering zoom level \(counts.keyframe) of \(counts.keyframes)")
      }
      return String(localized: "Rendering frame \(counts.frame) of \(counts.frames)")
    }
    private var detail: String {
      let counts = movies.counts
      if counts.onKeyframe || counts.frames == 0 {
        return counts.frame == 0
          ? "" : String(localized: "Frame \(counts.frame) of \(counts.frames)")
      }
      return counts.keyframes == 0
        ? "" : String(localized: "Zoom level \(counts.keyframe) of \(counts.keyframes)")
    }

    private var explanation: some View {
      VStack(alignment: .leading, spacing: 8) {
        Text("Mandelbrot journeys").font(.headline)
        Text(
          "Choose a place to start from and the app plans a continuous journey to this view. "
            + "If this view lies inside the place it is a single zoom; otherwise the journey "
            + "zooms out, travels across the set, then zooms in.")
        Text(
          "The suggested duration is the fastest comfortable pace. Edit Journey can slow "
            + "each part or add a hold, but cannot rush a camera move past that pace.")
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
          refreshJourney()
        })
    }
    private var duration: Binding<Double> {
      Binding(get: { settings.duration }, set: { settings.duration = $0.rounded() })
    }

    private func render() {
      problem = nil
      outcome = nil
      movies.output = nil
      do {
        guard let journey else {
          throw PrecisionError(
            journeyProblem ?? String(localized: "This journey can’t be planned."))
        }
        guard !durationIsTooShort else {
          throw PrecisionError(
            String(localized: "This journey needs at least \(seconds(requiredDuration)).")
          )
        }
        // Nothing behind the sheet is on screen, and a render wants the GPU and
        // the memory: stop the viewer's cache competing for both.  The
        // compositor resumes it on the first frame after the sheet closes.
        model.tiles.cancel()
        preview.cancel()
        movies.start(
          journey: journey, settings: movieSettings, colouring: model.colouring,
          to: library.destination(named: MovieNaming.fileName()))
      } catch {
        problem = MovieRenderer.message(for: error)
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

    private func refreshJourney() {
      do {
        let route = try Journey.planned(
          start: start, end: end, aspectRatio: Double(settings.width) / Double(settings.height))
        journey = route
        suggestedOverviewLog = overviewLog(route)
        journeyProblem = nil
        // A new, long route should not inherit the old sheet default and appear
        // broken.  Longer user choices are sacred; only lift an unsafe one.
        if settings.duration < route.minimumDuration {
          settings.duration = ceil(route.minimumDuration)
        }
      } catch {
        journey = nil
        journeyProblem = MovieRenderer.message(for: error)
      }
    }

    private func segmentDuration(_ index: Int) -> Binding<Double> {
      Binding(
        get: { journey?.segments[index].duration ?? 0 },
        set: { value in
          guard var route = journey else { return }
          route.segments[index].duration = max(route.segments[index].minimum, value)
          journey = route
          if settings.duration < route.requestedDuration {
            settings.duration = ceil(route.requestedDuration)
          }
        })
    }

    private func addHold() {
      guard var route = journey else { return }
      route.segments.append(
        Journey.Segment(
          kind: .hold, from: route.end, to: route.end, minimumDuration: 1,
          duration: 1, holdDuration: 1))
      journey = route
      if settings.duration < route.requestedDuration {
        settings.duration = ceil(route.requestedDuration)
      }
    }

    private var overviewScale: Binding<Double> {
      Binding(
        get: { journey.flatMap { overviewLog($0) } ?? suggestedOverviewLog ?? 0 },
        set: { value in
          guard let suggestedOverviewLog else { return }
          do {
            let route = try Journey.planned(
              start: start, end: end,
              aspectRatio: Double(settings.width) / Double(settings.height),
              overviewLogScale: min(value, suggestedOverviewLog))
            journey = route
            if settings.duration < route.minimumDuration {
              settings.duration = ceil(route.minimumDuration)
            }
          } catch {
            journeyProblem = MovieRenderer.message(for: error)
          }
        })
    }

    private func overviewLog(_ route: Journey) -> Double? {
      guard let travel = route.segments.first(where: { $0.kind == .travel }) else { return nil }
      return try? travel.from.viewport().logScale
    }

    private func overviewScaleDescription(_ logScale: Double) -> String {
      if logScale >= 0 { return ZoomFormat.string(logScale: logScale) }
      return String(localized: "\(ZoomFormat.string(logScale: -logScale)) wider")
    }

    private func seconds(_ value: Double) -> String {
      String(localized: "\(Int(ceil(value))) s")
    }

    /// A deliberately coarse local estimate, not a promise about a particular
    /// codec or Mac.  Travel is more expensive to render because it renders
    /// every output view exactly rather than resampling keyframes.
    private var estimatedFileSize: String {
      let bytes = Int64(MovieSettings.estimatedBytes(settings))
      let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
      return String(localized: "About \(size)")
    }

    private var estimatedRenderTime: String {
      let pixelFactor = Double(settings.width * settings.height) / Double(1920 * 1080)
      let units: Double
      if let journey, journey.isDirectDescent {
        units = settings.duration / 2.4
      } else {
        units = Double(settings.frameCount) * 0.11
      }
      return String(localized: "About \(seconds(max(1, units * pixelFactor))) on this Mac")
    }
  }

  /// Keeps the sheet useful on a large display without letting its ideal
  /// content height run under the Dock or off a smaller notebook screen.
  /// The window remains vertically resizable between these bounds; only the
  /// central form scrolls, so the footer actions never leave the screen.
  private struct MovieSheetSizePolicy: NSViewRepresentable {
    static let minimumContentHeight: CGFloat = 520
    static let initialMaximumHeight: CGFloat = 680
    static let comfortableMaximumHeight: CGFloat = 820
    static let minimumWidth: CGFloat = 600
    static let maximumWidth: CGFloat = 680

    @Binding var maximumHeight: CGFloat

    static func maximumContentHeight(forVisibleHeight height: CGFloat) -> CGFloat {
      min(
        comfortableMaximumHeight,
        max(minimumContentHeight, floor(height * 0.82)))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ProbeView {
      let probe = ProbeView()
      probe.windowChanged = { [weak coordinator = context.coordinator] window in
        coordinator?.attach(to: window)
      }
      return probe
    }

    func updateNSView(_ view: ProbeView, context: Context) {
      context.coordinator.policy = self
      context.coordinator.attach(to: view.window)
    }

    final class Coordinator {
      var policy: MovieSheetSizePolicy
      private weak var window: NSWindow?
      private var observations: [NSObjectProtocol] = []

      init(_ policy: MovieSheetSizePolicy) {
        self.policy = policy
      }

      deinit {
        observations.forEach(NotificationCenter.default.removeObserver)
      }

      func attach(to window: NSWindow?) {
        guard self.window !== window else {
          apply()
          return
        }
        observations.forEach(NotificationCenter.default.removeObserver)
        observations = []
        self.window = window
        guard let window else { return }
        let centre = NotificationCenter.default
        observations = [
          centre.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main
          ) { [weak self] _ in self?.apply() },
          centre.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
          ) { [weak self] _ in self?.apply() },
        ]
        apply()
      }

      private func apply() {
        guard let window else { return }
        let visibleHeight =
          window.screen?.visibleFrame.height
          ?? NSScreen.main?.visibleFrame.height
          ?? policy.maximumHeight
        let maximum = MovieSheetSizePolicy.maximumContentHeight(forVisibleHeight: visibleHeight)
        if policy.maximumHeight != maximum {
          policy.maximumHeight = maximum
        }
        window.contentMinSize = NSSize(
          width: MovieSheetSizePolicy.minimumWidth,
          height: MovieSheetSizePolicy.minimumContentHeight)
        window.contentMaxSize = NSSize(
          width: MovieSheetSizePolicy.maximumWidth,
          height: maximum)
        let size = window.contentLayoutRect.size
        if size.height > maximum {
          window.setContentSize(NSSize(width: size.width, height: maximum))
        }
      }
    }

    final class ProbeView: NSView {
      var windowChanged: ((NSWindow?) -> Void)?

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowChanged?(window)
      }
    }
  }

  #if DEBUG
    @MainActor private func previewModel() -> ExplorerModel {
      let model = ExplorerModel()
      model.apply(Location.gallery[1], record: false)
      return model
    }

    @MainActor private func journeyPreviewModel() -> ExplorerModel {
      let model = ExplorerModel()
      model.apply(Location.gallery[3], record: false)
      return model
    }

    #Preview("Settings") {
      MovieSheetMac(model: previewModel(), movies: .posed())
    }

    #Preview("Planned journey") {
      MovieSheetMac(
        model: journeyPreviewModel(), movies: .posed(), startingAt: Location.gallery[1])
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
