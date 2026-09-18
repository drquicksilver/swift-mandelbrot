#if os(macOS)
  import SwiftUI

  /// The Mac movie sheet, forked from the iOS `MovieView` so each platform can
  /// have the layout that suits it: a dialog here, a grouped form there.
  ///
  /// This is the layout alone.  Nothing is wired to `ExplorerModel` or
  /// `MovieRenderer` yet: the sheet is driven by the values below so that the
  /// previews can pose every state, and the wiring follows once the shape is
  /// right.

  /// What the sheet is showing.
  enum MoviePhase {
    case settings
    /// A render in flight.  `stage` is the headline -- what the renderer
    /// publishes -- and `detail` the quieter line under the bar.
    case rendering(progress: Double, stage: String, detail: String)
    case complete(MovieOutcome)
  }

  /// The facts about a finished movie, all of which are known after the fact
  /// rather than estimated.
  struct MovieOutcome {
    var path: String
    var frames: Int
    var seconds: Int
    var size: String
  }

  /// The journey the sheet describes, as text the layout can show before any of
  /// it is computed for real.
  struct MovieJourney {
    var from = "The whole set"
    var to = "Current view (18,420×)"
    var hint = "Zooms in from the starting place."
    var zoomRange = "1× → 18,420×"
    var keyframes = 13
  }

  struct MovieSheetMac: View {
    var journey = MovieJourney()
    var phase: MoviePhase = .settings
    @State private var settings = MovieSettings()
    @State private var folder = "~/Movies"

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
        thumbnail(caption: journey.from)
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 8) {
            Text("From:").frame(width: 52, alignment: .trailing)
            Picker("", selection: .constant(journey.from)) {
              Text(journey.from).tag(journey.from)
            }
            .labelsHidden()
          }
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("To:").frame(width: 52, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
              Text(journey.to)
              Text(journey.hint).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        thumbnail(caption: "Current view")
      }
    }

    /// A placeholder until the ends are rendered for real: a slot the right
    /// shape, so the layout can be judged without waiting on the GPU.
    private func thumbnail(caption: String) -> some View {
      VStack(spacing: 6) {
        RoundedRectangle(cornerRadius: 6)
          .fill(
            LinearGradient(
              colors: [
                Color(red: 0.36, green: 0.44, blue: 0.58),
                Color(red: 0.16, green: 0.2, blue: 0.3),
              ],
              startPoint: .topLeading, endPoint: .bottomTrailing)
          )
          .frame(width: 116, height: 70)
        Text(caption).font(.caption).foregroundStyle(.secondary)
      }
    }

    // MARK: Settings

    private var settingsCard: some View {
      HStack(alignment: .top, spacing: 16) {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
          GridRow {
            Text("Resolution:").gridColumnAlignment(.trailing)
            Picker("", selection: .constant("1080p")) {
              Text("1080p (1920 × 1080)").tag("1080p")
            }
            .labelsHidden()
            .frame(width: 180)
          }
          GridRow {
            Text("Duration:").gridColumnAlignment(.trailing)
            HStack(spacing: 6) {
              TextField("", value: .constant(12), format: .number).frame(width: 56)
              Text("seconds").foregroundStyle(.secondary)
            }
          }
          GridRow {
            Text("Frame rate:").gridColumnAlignment(.trailing)
            Picker("", selection: .constant(30)) { Text("30 fps").tag(30) }
              .labelsHidden()
          }
          GridRow {
            Text("Palette cycles:").gridColumnAlignment(.trailing)
            HStack(spacing: 6) {
              TextField("", value: .constant(0), format: .number).frame(width: 56)
              Stepper("", value: .constant(0)).labelsHidden()
            }
          }
          GridRow {
            Color.clear.frame(height: 0)
            Toggle("Ease in and out", isOn: .constant(true))
          }
        }
        Divider()
        statistics
      }
    }

    /// Only what is known rather than guessed: the frame count and the size come
    /// straight from the settings, the zoom range and the keyframe count from
    /// the path.  Keyframes are the whole cost of a render -- one per zoom level
    /// -- which is why they are here rather than a render-time estimate.
    private var statistics: some View {
      VStack(alignment: .leading, spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text("\(settings.frameCount) frames")
          Text(verbatim: "\(settings.width) × \(settings.height)").foregroundStyle(.secondary)
        }
        Divider()
        VStack(alignment: .leading, spacing: 2) {
          Text("Zoom range").font(.caption).foregroundStyle(.secondary)
          Text(journey.zoomRange)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text("Keyframes").font(.caption).foregroundStyle(.secondary)
          Text("\(journey.keyframes)")
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
          TextField("", text: $folder).disabled(true)
          Button("Choose…") {}
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
            Button("Reveal in Finder") {}
            Button {
            } label: {
              Label("Share…", systemImage: "square.and.arrow.up")
            }
          }
          .padding(.top, 4)
        }
        Spacer(minLength: 0)
        // The player goes here once there is a file to play.
        RoundedRectangle(cornerRadius: 6)
          .fill(Color.black)
          .frame(width: 140, height: 84)
          .overlay {
            Image(systemName: "play.circle.fill")
              .font(.title)
              .foregroundStyle(.white.opacity(0.8))
          }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
      switch phase {
      case .rendering(let progress, let stage, let detail):
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text(stage).font(.headline)
            Spacer()
            Text("\(Int((progress * 100).rounded()))%").foregroundStyle(.secondary)
          }
          ProgressView(value: progress)
          HStack {
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") {}
          }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
      case .settings, .complete:
        HStack {
          Button {
          } label: {
            Image(systemName: "questionmark")
          }
          .buttonStyle(.bordered)
          .clipShape(Circle())
          .help("About zoom movies")
          Spacer()
          if case .complete = phase {
            Button("Close") {}
            Button("Render Another Movie") {}.buttonStyle(.borderedProminent)
          } else {
            Button("Cancel") {}
            Button("Render Movie") {}.buttonStyle(.borderedProminent)
          }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
      }
    }
  }

  #if DEBUG
    #Preview("Settings") {
      MovieSheetMac()
    }

    #Preview("Rendering") {
      MovieSheetMac(
        phase: .rendering(
          progress: 0.39, stage: "Rendering frame 142 of 360", detail: "Keyframe 6 of 13"))
    }

    #Preview("Complete") {
      MovieSheetMac(
        phase: .complete(
          MovieOutcome(
            path: "~/Movies/Mandelbrot zoom 2026-09-18-175406.mov",
            frames: 360, seconds: 12, size: "24.3 MB")))
    }
  #endif
#endif
