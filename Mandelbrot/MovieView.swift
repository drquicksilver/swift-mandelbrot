import AVKit
import SwiftUI

/// Picks the ends of a zoom movie, renders it in the background with progress,
/// and plays the result before offering to share it.
struct MovieView: View {
  @ObservedObject var model: ExplorerModel
  /// The renderer publishes progress, the stage, completion and the finished
  /// file.  The sheet observes it directly: observing the model alone showed
  /// none of it, because the model does not republish what the renderer says.
  @ObservedObject private var movies: MovieRenderer
  #if os(macOS)
    @ObservedObject private var library = MovieLibrary.shared
  #endif
  /// `movies` is the seam the previews use to pose a render that is not
  /// happening; the app always takes the model's own renderer.
  init(model: ExplorerModel, movies: MovieRenderer? = nil) {
    _model = ObservedObject(wrappedValue: model)
    _movies = ObservedObject(wrappedValue: movies ?? model.movies)
  }
  @Environment(\.dismiss) private var dismiss
  @State private var startChoice: UUID?
  @State private var settings = MovieSettings()
  @State private var problem: String?
  @State private var player: AVPlayer?
  private var start: Location {
    let places = Location.gallery + model.bookmarks.bookmarks
    return places.first { $0.id == startChoice } ?? Location.gallery[0]
  }
  private var end: Location { model.location }
  var body: some View {
    NavigationStack {
      Form {
        Section("Journey") {
          Picker("From", selection: $startChoice) {
            ForEach(Location.gallery + model.bookmarks.bookmarks) { place in
              Text(place.name.isEmpty ? place.zoomDescription : place.name).tag(place.id as UUID?)
            }
          }
          LabeledContent("To", value: "This view, \(end.zoomDescription)")
          if let levels = try? ZoomPath(start: start, end: end).keyframeLevels.count {
            LabeledContent("Keyframes", value: "\(levels)")
          } else {
            Text("Zoom in further than the starting place.").foregroundStyle(.secondary)
          }
        }
        Section("Movie") {
          Picker("Resolution", selection: resolution) {
            ForEach(MovieSettings.resolutions, id: \.name) { option in
              Text(option.name).tag(option.name)
            }
          }
          ValueStepper("Duration", value: $settings.duration, in: 2...120, unit: "s")
          Picker("Frame rate", selection: $settings.framesPerSecond) {
            Text("24").tag(24)
            Text("30").tag(30)
            Text("60").tag(60)
          }
          ValueStepper("Palette cycles", value: $settings.paletteCycles, in: 0...16)
          Toggle("Ease in and out", isOn: $settings.eased)
          LabeledContent("Frames", value: "\(settings.frameCount)")
        }
        #if os(macOS)
          Section("Saved to") {
            LabeledContent("Folder", value: library.folder.lastPathComponent)
            HStack {
              Button("Choose…") { library.choose() }
              Button("Reveal in Finder") { library.reveal(library.folder) }
            }
          }
        #endif
        Section {
          if movies.isRendering {
            VStack(alignment: .leading) {
              ProgressView(value: movies.progress)
              Text(movies.stage).font(.caption).foregroundStyle(.secondary)
            }
            Button("Cancel", role: .destructive) { movies.cancel() }
          } else {
            Button("Render movie") { render() }
          }
          if let error = movies.error ?? problem {
            Text(error).font(.caption).foregroundStyle(.red)
          }
          if let output = movies.output, !movies.isRendering {
            // The finished movie plays here before it goes anywhere.
            VideoPlayer(player: player)
              .frame(height: 220)
              .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
              ShareLink("Share movie", item: output)
              #if os(macOS)
                Button("Reveal in Finder") { library.reveal(output) }
              #endif
            }
          }
        }
      }
      .navigationTitle("Zoom Movie")
      .toolbar { Button("Done") { dismiss() } }
    }
    .frame(minWidth: 420, minHeight: 480)
    .onAppear {
      startChoice = startChoice ?? Location.gallery[0].id
      // Reopening the sheet after a render finds the finished movie already
      // there: `onChange` will not fire for it, so the player is built here.
      player = player ?? movies.output.map { AVPlayer(url: $0) }
    }
    .onChange(of: movies.output) { _, url in
      player?.pause()
      player = url.map { AVPlayer(url: $0) }
    }
    .onDisappear { player?.pause() }
  }
  private var resolution: Binding<String> {
    Binding(
      get: {
        MovieSettings.resolutions.first { $0.width == settings.width }?.name ?? "1080p"
      },
      set: { name in
        guard let option = MovieSettings.resolutions.first(where: { $0.name == name }) else {
          return
        }
        settings.width = option.width
        settings.height = option.height
      })
  }
  private func render() {
    problem = nil
    do {
      let path = try ZoomPath(start: start, end: end, eased: settings.eased)
      // A render used to land in `temporaryDirectory`, one purge from gone.
      #if os(macOS)
        let url = library.destination(named: MovieNaming.fileName())
      #else
        // iOS has no folder to choose: the share sheet, where Save to Files
        // always exists, is how a movie leaves the app.
        let url = FileManager.default.temporaryDirectory
          .appendingPathComponent(MovieNaming.fileName())
      #endif
      // Nothing behind the sheet is on screen, and a render wants the GPU and the
      // memory: stop the viewer's cache competing for both.  Its next update
      // resumes it, which the compositor does on the first frame after the sheet
      // closes.
      model.tiles.cancel()
      model.movies.start(
        path: path, settings: settings, colouring: model.colouring, to: url)
    } catch {
      problem = error.localizedDescription
    }
  }
}

#if DEBUG
  /// The previews put the viewer deep inside Seahorse Valley, so the journey has
  /// a real destination and a keyframe count to show.
  @MainActor private func previewModel() -> ExplorerModel {
    let model = ExplorerModel()
    model.apply(Location.gallery[1], record: false)
    return model
  }

  #Preview("Settings") {
    MovieView(model: previewModel(), movies: .posed())
  }

  #Preview("Rendering") {
    MovieView(
      model: previewModel(),
      movies: .posed(progress: 0.42, stage: "Keyframe 6 of 13"))
  }

  #Preview("Failed") {
    MovieView(model: previewModel(), movies: .posed(failure: "The movie writer rejected its input"))
  }

  #Preview("Finished") {
    // The player is empty here: no render has written the file a preview names.
    MovieView(
      model: previewModel(),
      movies: .posed(
        output: FileManager.default.temporaryDirectory
          .appendingPathComponent("Mandelbrot zoom preview.mov")))
  }
#endif
