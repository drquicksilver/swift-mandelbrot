// Places on iPhone and iPad: a grouped list of the famous places and the
// bookmarks, each opening with a flight to it and offering a link to share.
// The Mac has its own library, PlacesSheetMac.swift.

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
            // The first click after typing used to go to the field.  On the
            // Mac a bordered button takes it; on iPhone a borderless one keeps
            // a tap on the row from firing it.
            Button("Bookmark", action: bookmark)
              // Without a new name it would only find the one already there.
              .disabled(model.isBookmarkedHere && name.isEmpty)
              #if os(macOS)
                .buttonStyle(.bordered)
              #else
                .buttonStyle(.borderless)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
              #endif
          }
          // Both rows lead with a control whose text is inset, and the list
          // aligned their separators to that text, leaving a stub.
          .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
          ShareLink("Share Link", item: model.location.url)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
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
        model.travel(to: place)
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
