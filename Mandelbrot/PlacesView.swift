import SwiftUI

/// The starter gallery and the user's bookmarks, each with a link to share.
struct PlacesView: View {
  @ObservedObject var model: ExplorerModel
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  var body: some View {
    NavigationStack {
      List {
        Section("This view") {
          LabeledContent("Centre", value: model.viewport.centerDescription)
            .lineLimit(2).truncationMode(.middle).font(.caption.monospaced())
          LabeledContent("Scale", value: model.viewport.scaleDescription)
            .lineLimit(1).truncationMode(.tail).font(.caption.monospaced())
          HStack {
            TextField("Name this view", text: $name)
            Button("Bookmark") {
              model.bookmarkCurrentView(named: name)
              name = ""
            }
          }
          ShareLink("Share link", item: model.location.url)
        }
        if !model.bookmarks.bookmarks.isEmpty {
          Section("Bookmarks") {
            ForEach(model.bookmarks.bookmarks) { place in
              row(place)
            }
            .onDelete { offsets in
              for index in offsets { model.bookmarks.remove(model.bookmarks.bookmarks[index]) }
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
  private func row(_ place: Location) -> some View {
    HStack {
      Button {
        model.apply(place)
        dismiss()
      } label: {
        VStack(alignment: .leading) {
          Text(place.name.isEmpty ? "Untitled" : place.name)
          Text("\(place.scale)× · \(place.palette.title)")
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
