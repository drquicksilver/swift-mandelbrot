#if os(macOS)
  import SwiftUI
  import UniformTypeIdentifiers

  /// The Mac's Places, a library of pictures: this view at the top, ready to
  /// bookmark, then your bookmarks and the famous places as grids of rendered
  /// thumbnails.  Forked from the iOS `PlacesView`, as the movie sheet is.
  ///
  /// A click selects a place, a double-click goes there, and each card's menu
  /// (or its context menu) holds everything else you can do to it.
  struct PlacesSheetMac: View {
    @ObservedObject var model: ExplorerModel
    /// Observed in its own right: the model does not republish the store.
    @ObservedObject private var bookmarks: LocationStore
    @ObservedObject private var thumbnails = PlaceThumbnails.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var search = ""
    @State private var visibleSection = PlacesSection.bookmarks
    @State private var userScrolling = false
    @State private var reordering: Bool
    @State private var selection: UUID?
    @State private var dragging: Location?
    @State private var renaming: Location?
    @State private var draftName = ""
    @State private var deleting: Location?
    @FocusState private var searching: Bool

    /// `reordering` is a seam the previews pose a state through.
    init(model: ExplorerModel, reordering: Bool = false) {
      _model = ObservedObject(wrappedValue: model)
      _bookmarks = ObservedObject(wrappedValue: model.bookmarks)
      _reordering = State(initialValue: reordering)
    }

    private var query: String { search.trimmingCharacters(in: .whitespaces) }
    private func matches(_ place: Location) -> Bool {
      query.isEmpty || place.name.localizedStandardContains(query)
    }
    private var shownBookmarks: [Location] { bookmarks.bookmarks.filter(matches) }
    private var shownFamous: [Location] { Location.gallery.filter(matches) }
    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: 18)]

    var body: some View {
      ScrollViewReader { scroller in
        VStack(spacing: 0) {
          header(scroller)
          ScrollView {
            VStack(alignment: .leading, spacing: 22) {
              thisViewCard
              bookmarksSection.id(PlacesSection.bookmarks)
              Divider()
              famousSection.id(PlacesSection.famous)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
          }
          .coordinateSpace(.named(Self.scrollSpace))
          .onScrollPhaseChange { _, phase in
            userScrolling = phase == .interacting || phase == .decelerating
          }
          Divider()
          footer
        }
      }
      .frame(
        minWidth: 720, idealWidth: 980, maxWidth: 1280,
        minHeight: 560, idealHeight: 820, maxHeight: .infinity
      )
      .background(Color(nsColor: .windowBackgroundColor))
      .onExitCommand { dismiss() }
      .onDeleteCommand {
        if let selection, let place = bookmarks.bookmarks.first(where: { $0.id == selection }) {
          deleting = place
        }
      }
      .onAppear { searching = false }
      .onDisappear { thumbnails.cancelPending() }
      .alert("Rename Bookmark", isPresented: isPresent($renaming)) {
        TextField("Name", text: $draftName)
        Button("Rename") {
          if let renaming {
            let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { bookmarks.rename(renaming, to: name) }
          }
        }
        .keyboardShortcut(.defaultAction)
        Button("Cancel", role: .cancel) {}
      }
      .confirmationDialog(
        "Delete “\(deleting.map(title) ?? "")”?", isPresented: isPresent($deleting)
      ) {
        Button("Delete", role: .destructive) {
          if let deleting { bookmarks.remove(deleting) }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("The bookmark is removed from Places. You can’t undo this.")
      }
    }

    // MARK: Header and footer

    private func header(_ scroller: ScrollViewProxy) -> some View {
      VStack(spacing: 12) {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: ToolbarAction.places.icon + ".fill")
            .font(.title)
            .foregroundStyle(.green)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text("Places").font(.title2.bold())
            Text("Bookmark this view, and go back to the places you have found.")
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 16)
          searchField.frame(width: 240)
        }
        Picker(
          "Show",
          selection: Binding(
            get: { visibleSection },
            set: { section in
              visibleSection = section
              withAnimation(reduceMotion ? nil : .default) {
                scroller.scrollTo(section, anchor: .top)
              }
            })
        ) {
          Text("My Bookmarks (\(bookmarks.bookmarks.count))").tag(PlacesSection.bookmarks)
          Text("Famous Places (\(Location.gallery.count))").tag(PlacesSection.famous)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
      }
      .padding(.horizontal, 24)
      .padding(.top, 20)
      .padding(.bottom, 12)
    }

    private var searchField: some View {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search places", text: $search)
          .textFieldStyle(.plain)
          .focused($searching)
        if !search.isEmpty {
          Button {
            search = ""
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Clear Search")
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(.background, in: RoundedRectangle(cornerRadius: 7))
      .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
    }

    private var footer: some View {
      HStack(spacing: 8) {
        Image(systemName: reordering ? "hand.draw" : "lightbulb")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(tip).font(.callout).foregroundStyle(.secondary)
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
          .controlSize(.large)
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 14)
    }

    private var tip: String {
      if reordering { return String(localized: "Drag your bookmarks into the order you want.") }
      return reduceMotion
        ? String(localized: "Double-click a place to go there.")
        : String(localized: "Double-click a place to go there with a smooth zoom.")
    }

    // MARK: This view

    private var thisViewCard: some View {
      let here = model.location
      return HStack(alignment: .center, spacing: 18) {
        thumbnail(here)
          .frame(width: 200, height: 112)
          .clipShape(RoundedRectangle(cornerRadius: 8))
        VStack(alignment: .leading, spacing: 6) {
          Text("Bookmark This View").font(.headline)
          Text(
            "Keep this view in Places, with its palette, colour spacing, colour shift and detail."
          )
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          Button {
            model.bookmarkCurrentView()
          } label: {
            Label("Bookmark This View", systemImage: "bookmark")
          }
          .buttonStyle(.borderedProminent)
          .fixedSize()
          .padding(.top, 4)
        }
        .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
        Divider()
        // The centre is the one number here that needs every digit, so it
        // can be selected and copied; the zoom is for reading.
        VStack(alignment: .leading, spacing: 6) {
          Text("This view").foregroundStyle(.secondary)
          Text(model.viewport.centerDescription)
            .font(.callout.monospaced())
            .lineLimit(3)
            .truncationMode(.middle)
            .textSelection(.enabled)
          Text("Zoom \(model.viewport.zoomDescription)").font(.callout.monospaced())
        }
        .frame(minWidth: 160, idealWidth: 260, maxWidth: 280, alignment: .leading)
      }
      .fixedSize(horizontal: false, vertical: true)
      .padding(14)
      .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }

    // MARK: Sections

    private var bookmarksSection: some View {
      VStack(alignment: .leading, spacing: 14) {
        sectionHeader(
          "My Bookmarks (\(bookmarks.bookmarks.count))", systemImage: "bookmark.fill", tint: .blue,
          detail: "The views you have bookmarked, each with its own colours and detail."
        ) {
          if bookmarks.bookmarks.count > 1 && query.isEmpty {
            Button(reordering ? "Done Reordering" : "Reorder") {
              reordering.toggle()
            }
          }
        }
        .background(sectionTracker(.bookmarks))
        if bookmarks.bookmarks.isEmpty {
          emptyBookmarks
        } else if shownBookmarks.isEmpty {
          noMatches
        } else {
          LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(shownBookmarks) { place in
              card(place, isBookmark: true)
            }
          }
        }
      }
    }

    private var famousSection: some View {
      VStack(alignment: .leading, spacing: 14) {
        sectionHeader(
          "Famous Places (\(Location.gallery.count))", systemImage: "star.fill", tint: .orange,
          detail: "Well-known places in the set, each with a palette of its own."
        ) { EmptyView() }
        .background(sectionTracker(.famous))
        if shownFamous.isEmpty {
          noMatches
        } else {
          LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(shownFamous) { place in
              card(place, isBookmark: false)
            }
          }
        }
      }
    }

    private func sectionHeader<Accessory: View>(
      _ title: String, systemImage: String, tint: Color, detail: String,
      @ViewBuilder accessory: () -> Accessory
    ) -> some View {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: systemImage)
          .font(.title2)
          .foregroundStyle(tint)
          .frame(width: 28)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
          Text(detail).foregroundStyle(.secondary)
        }
        Spacer()
        accessory()
      }
    }

    private var emptyBookmarks: some View {
      VStack(spacing: 6) {
        Image(systemName: "bookmark")
          .font(.title)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text("No bookmarks yet").font(.headline)
        Text("When you find a view worth keeping, bookmark it here or press ⌘D.")
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 28)
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }

    private var noMatches: some View {
      Text("No places match “\(query)”.")
        .foregroundStyle(.secondary)
        .padding(.vertical, 8)
    }

    /// The picker follows the scrolling: once the famous places' heading is
    /// in the upper half of the list, they are what you are looking at.  A
    /// click on the picker scrolls instead, and is not overruled by it.
    private func sectionTracker(_ section: PlacesSection) -> some View {
      GeometryReader { proxy in
        Color.clear
          .onChange(of: proxy.frame(in: .named(Self.scrollSpace)).minY) { _, top in
            guard userScrolling, section == .famous else { return }
            visibleSection = top < 260 ? .famous : .bookmarks
          }
      }
    }
    private static let scrollSpace = "places"

    // MARK: A place

    private func card(_ place: Location, isBookmark: Bool) -> some View {
      let isCurrent = model.isShowing(place)
      let isSelected = selection == place.id
      return VStack(alignment: .leading, spacing: 3) {
        thumbnail(place)
          .aspectRatio(16 / 9, contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .overlay {
            RoundedRectangle(cornerRadius: 8)
              .strokeBorder(
                isCurrent ? Color.accentColor : Color.primary.opacity(0.1),
                lineWidth: isCurrent ? 3 : 1)
          }
          .overlay(alignment: .topLeading) {
            if isCurrent {
              Text("Current")
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Color.accentColor, in: Capsule())
                .padding(8)
            }
          }
          .overlay(alignment: .topTrailing) {
            if !reordering {
              Menu {
                actions(for: place, isBookmark: isBookmark)
              } label: {
                // A plain button takes clicks only on its label, so the
                // label is the whole chip, not just the glyph.
                Image(systemName: "ellipsis")
                  .frame(width: 28, height: 22)
                  .background(
                    Color(nsColor: .windowBackgroundColor).opacity(0.9),
                    in: RoundedRectangle(cornerRadius: 6)
                  )
                  .contentShape(Rectangle())
              }
              .menuStyle(.button)
              .buttonStyle(.plain)
              .menuIndicator(.hidden)
              .fixedSize()
              .padding(8)
              .accessibilityLabel("Actions")
            }
          }
          .padding(.bottom, 5)
        Text(title(place)).font(.headline).lineLimit(1)
        Text("\(place.zoomDescription) · \(place.palette.title)")
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if isBookmark {
          Text("Bookmarked \(place.created.formatted(date: .abbreviated, time: .omitted))")
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .padding(6)
      .background {
        RoundedRectangle(cornerRadius: 12)
          .fill(isSelected ? Color.accentColor.opacity(0.14) : .clear)
      }
      .overlay {
        if reordering && isBookmark {
          RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
              Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
      }
      .opacity(dragging?.id == place.id ? 0.4 : 1)
      .contentShape(RoundedRectangle(cornerRadius: 12))
      .onTapGesture(count: 2) { open(place) }
      .simultaneousGesture(
        TapGesture().onEnded {
          selection = place.id
          // The field gives up the keyboard, so Delete reaches the card.
          searching = false
        }
      )
      .contextMenu { actions(for: place, isBookmark: isBookmark) }
      .modifier(
        Reorderable(
          place: place, isEnabled: reordering && isBookmark, dragging: $dragging,
          bookmarks: bookmarks)
      )
      .task(id: LocationThumbnail.key(place)) { thumbnails.request(place) }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
      .accessibilityAction { open(place) }
    }

    @ViewBuilder private func actions(for place: Location, isBookmark: Bool) -> some View {
      Button("Open", systemImage: "play") { open(place) }
      if isBookmark {
        Button("Rename…", systemImage: "pencil") {
          draftName = place.name
          renaming = place
        }
      }
      ShareLink("Share…", item: place.url)
      if isBookmark {
        Divider()
        let index = bookmarks.bookmarks.firstIndex { $0.id == place.id } ?? 0
        Button("Move Up", systemImage: "arrow.up") { bookmarks.move(place, by: -1) }
          .disabled(index == 0)
        Button("Move Down", systemImage: "arrow.down") { bookmarks.move(place, by: 1) }
          .disabled(index == bookmarks.bookmarks.count - 1)
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { deleting = place }
      }
    }

    @ViewBuilder private func thumbnail(_ place: Location) -> some View {
      ZStack {
        Color.black.opacity(0.85)
        if let image = thumbnails.image(for: place) {
          Image(decorative: image, scale: 2)
            .resizable()
            .aspectRatio(contentMode: .fill)
        } else {
          // The palette stands in for the picture while it is drawn.
          PalettePreview(palette: place.palette).opacity(0.35)
          ProgressView().controlSize(.small).environment(\.colorScheme, .dark)
        }
      }
      .onAppear { thumbnails.request(place) }
    }

    private func title(_ place: Location) -> String {
      place.name.isEmpty ? String(localized: "Untitled") : place.name
    }

    private func open(_ place: Location) {
      model.travel(to: place)
      dismiss()
    }

    private func isPresent(_ item: Binding<Location?>) -> Binding<Bool> {
      Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
  }

  enum PlacesSection: Hashable {
    case bookmarks, famous
  }

  /// Drag-to-reorder for a bookmark card: the dragged card takes each
  /// card's place as it passes over it, so the grid shows the order the drop
  /// will leave.
  private struct Reorderable: ViewModifier {
    let place: Location
    let isEnabled: Bool
    @Binding var dragging: Location?
    let bookmarks: LocationStore

    func body(content: Content) -> some View {
      if isEnabled {
        content
          .onDrag {
            dragging = place
            return NSItemProvider(object: place.id.uuidString as NSString)
          }
          .onDrop(
            of: [.text], delegate: Drop(place: place, dragging: $dragging, bookmarks: bookmarks))
      } else {
        content
      }
    }

    struct Drop: DropDelegate {
      let place: Location
      @Binding var dragging: Location?
      let bookmarks: LocationStore
      func dropEntered(info: DropInfo) {
        guard let dragging, dragging.id != place.id else { return }
        withAnimation { bookmarks.move(dragging, to: place) }
      }
      func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
      func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
      }
    }
  }

  #if DEBUG
    /// Defaults held in memory, so a preview never writes to the app's own.
    private final class PreviewDefaults: UserDefaults, @unchecked Sendable {
      private var values: [String: Any] = [:]
      init() { super.init(suiteName: nil)! }
      override func object(forKey key: String) -> Any? { values[key] }
      override func set(_ value: Any?, forKey key: String) { values[key] = value }
      override func removeObject(forKey key: String) { values[key] = nil }
    }

    @MainActor private func placesPreviewModel(bookmarked: Bool) -> ExplorerModel {
      let defaults = PreviewDefaults()
      let store = LocationStore(defaults: defaults)
      let model = ExplorerModel(bookmarks: store, defaults: defaults)
      if bookmarked {
        let day: TimeInterval = 86_400
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let saved = [
          Location(
            name: "Next Zoom", real: "-0.7436438", imag: "0.1318259", scale: "890",
            palette: .ice, created: now - 26 * day),
          Location(
            name: "Spiral Detail", real: "-0.74364386", imag: "0.13182590", scale: "1.2e4",
            palette: .fire, created: now - 20 * day),
          Location(
            name: "Twilight Reach", real: "-0.75", imag: "0.1", scale: "578",
            palette: .twilight, created: now - 11 * day),
        ]
        saved.forEach(store.add)
        model.apply(saved[2], record: false)
      }
      return model
    }

    /// Seeds the thumbnail cache from `Preview Content`, drawn beforehand by
    /// the app's own `--render --pipeline tiles`, and shows the sheet at its
    /// ideal size.
    private struct PlacesPreview: View {
      let model: ExplorerModel
      var reordering = false
      var width: CGFloat = 980
      var height: CGFloat = 820
      var body: some View {
        let _ = seedThumbnails(model)
        PlacesSheetMac(model: model, reordering: reordering).frame(width: width, height: height)
      }
    }

    @MainActor private func seedThumbnails(_ model: ExplorerModel) {
      func seed(_ name: String, _ place: Location) {
        guard
          let image = NSImage(named: name)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        PlaceThumbnails.shared.seed(image, for: place)
      }
      for (index, place) in Location.gallery.enumerated() { seed("famous-\(index)", place) }
      let names = ["Twilight Reach", "Spiral Detail", "Next Zoom"]
      for place in model.bookmarks.bookmarks {
        if let index = names.firstIndex(of: place.name) { seed("bookmark-\(index)", place) }
      }
      if let current = model.bookmarks.bookmarks.first(where: model.isShowing) {
        var here = model.location
        here.name = current.name
        if let index = names.firstIndex(of: current.name) { seed("bookmark-\(index)", here) }
      } else {
        seed("famous-0", model.location)
      }
    }

    #Preview("Bookmarks") {
      PlacesPreview(model: placesPreviewModel(bookmarked: true))
    }

    #Preview("No bookmarks") {
      PlacesPreview(model: placesPreviewModel(bookmarked: false))
    }

    #Preview("Reordering") {
      PlacesPreview(model: placesPreviewModel(bookmarked: true), reordering: true)
    }

    #Preview("Minimum size") {
      PlacesPreview(model: placesPreviewModel(bookmarked: true), width: 720, height: 560)
    }
  #endif
#endif
