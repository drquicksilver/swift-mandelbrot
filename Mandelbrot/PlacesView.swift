import SwiftUI

/// The starter gallery and the user's bookmarks, each with a link to share.
struct PlacesView: View {
  @ObservedObject var model: ExplorerModel
  /// Observed in its own right: the model does not republish the store, so
  /// a new bookmark reached the list only on the next unrelated redraw.
  @ObservedObject private var bookmarks: LocationStore
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  init(model: ExplorerModel) {
    _model = ObservedObject(wrappedValue: model)
    _bookmarks = ObservedObject(wrappedValue: model.bookmarks)
  }
  var body: some View {
    NavigationStack {
      List {
        Section("This view") {
          // The centre is the one number here that needs every digit, so it
          // can be selected and copied; the zoom is for reading.
          LabeledContent("Centre") {
            Text(model.viewport.centerDescription)
              .lineLimit(2).truncationMode(.middle).font(.caption.monospaced())
              .textSelection(.enabled)
          }
          LabeledContent("Zoom", value: model.viewport.zoomDescription)
          HStack {
            TextField("Name this view", text: $name, prompt: Text(model.location.suggestedName))
              .onSubmit(bookmark)
            // Borderless, so a click or tap reaches the button itself rather
            // than the row: a bordered button in a list row shares its hits
            // with the row, and the first click after typing went to the field.
            Button("Bookmark", action: bookmark)
              #if os(macOS)
                .buttonStyle(.bordered)
              #else
                .buttonStyle(.borderless)
              #endif
          }
          ShareLink("Share link", item: model.location.url)
        }
        if !bookmarks.bookmarks.isEmpty {
          Section("Bookmarks") {
            ForEach(bookmarks.bookmarks) { place in
              row(place)
            }
            .onDelete { offsets in
              for index in offsets { bookmarks.remove(bookmarks.bookmarks[index]) }
            }
          }
        }
        Section("Famous places") {
          ForEach(Location.gallery) { place in
            row(place)
          }
        }
      }
      .navigationTitle("Places")
      .toolbar { Button("Done") { dismiss() } }
    }
    .frame(minWidth: 380, minHeight: 460)
  }
  private func bookmark() {
    model.bookmarkCurrentView(named: name)
    name = ""
  }
  private func row(_ place: Location) -> some View {
    HStack {
      Button {
        model.apply(place)
        dismiss()
      } label: {
        VStack(alignment: .leading) {
          Text(place.name.isEmpty ? String(localized: "Untitled") : place.name)
          Text("\(place.zoomDescription) · \(place.palette.title)")
            .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      ShareLink(item: place.url) { Image(systemName: "square.and.arrow.up") }
        .labelStyle(.iconOnly)
    }
  }
}
