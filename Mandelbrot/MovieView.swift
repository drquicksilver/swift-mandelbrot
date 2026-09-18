import SwiftUI

/// Picks the ends of a zoom movie, renders it in the background with progress,
/// and offers the result to share.
struct MovieView: View {
  @ObservedObject var model: ExplorerModel
  @Environment(\.dismiss) private var dismiss
  @State private var startChoice: UUID?
  @State private var settings = MovieSettings()
  @State private var problem: String?
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
              Text(place.name.isEmpty ? place.scale : place.name).tag(place.id as UUID?)
            }
          }
          LabeledContent("To", value: "This view, \(end.scale)×")
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
          Stepper(
            "Duration \(Int(settings.duration)) s", value: $settings.duration, in: 2...120,
            step: 1)
          Picker("Frame rate", selection: $settings.framesPerSecond) {
            Text("24").tag(24)
            Text("30").tag(30)
            Text("60").tag(60)
          }
          Stepper(
            "Palette cycles \(settings.paletteCycles, specifier: "%.0f")",
            value: $settings.paletteCycles, in: 0...16, step: 1)
          Toggle("Ease in and out", isOn: $settings.eased)
          LabeledContent("Frames", value: "\(settings.frameCount)")
        }
        Section {
          if model.movies.isRendering {
            VStack(alignment: .leading) {
              ProgressView(value: model.movies.progress)
              Text(model.movies.stage).font(.caption).foregroundStyle(.secondary)
            }
            Button("Cancel", role: .destructive) { model.movies.cancel() }
          } else {
            Button("Render movie") { render() }
          }
          if let error = model.movies.error ?? problem {
            Text(error).font(.caption).foregroundStyle(.red)
          }
          if let output = model.movies.output, !model.movies.isRendering {
            ShareLink("Share movie", item: output)
          }
        }
      }
      .navigationTitle("Zoom Movie")
      .toolbar { Button("Done") { dismiss() } }
    }
    .frame(minWidth: 420, minHeight: 480)
    .onAppear { startChoice = startChoice ?? Location.gallery[0].id }
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
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mandelbrot-zoom-\(Int(Date().timeIntervalSince1970)).mov")
      // Nothing behind the sheet is on screen, and a render wants the GPU and the
      // memory: stop the viewer's cache competing for both.  Its next update
      // resumes it, which the compositor does on the first frame after the sheet
      // closes.
      model.tiles.cancel()
      model.movies.start(
        path: path, settings: settings, colouring: model.colouring, to: url)
    } catch {
      problem = String(describing: error)
    }
  }
}
