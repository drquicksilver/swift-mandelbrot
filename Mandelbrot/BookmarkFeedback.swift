import Combine
import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// “Saved to Places”, with a way back and a way to name it.  It confirms
/// what happened; on the Mac the flight shows where the view went.
struct BookmarkNoticeCapsule: View {
  let notice: BookmarkNotice
  var undo: () -> Void
  var name: () -> Void
  var dismiss: () -> Void
  @State private var hovering = false
  /// Long enough to reach for Undo, short enough not to linger.
  static let seconds = 5.0

  var body: some View {
    HStack(spacing: 12) {
      thumbnail
      VStack(alignment: .leading, spacing: 2) {
        Text(notice.isNew ? "Saved to Places" : "Already in Places")
          .font(.subheadline.weight(.semibold))
        Text(notice.place.name)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .fixedSize(horizontal: true, vertical: false)
      .frame(minWidth: 140, maxWidth: 320, alignment: .leading)
      if notice.isNew {
        Button("Undo", action: undo)
      }
      Button("Name…", action: name)
    }
    .buttonStyle(.bordered)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .foregroundStyle(.white)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.15)))
    .environment(\.colorScheme, .dark)
    .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    .accessibilityElement(children: .contain)
    #if os(macOS)
      .onHover { hovering = $0 }
    #endif
    .task(id: notice.id) {
      // Waits while the pointer rests on it, so it never leaves under a
      // reaching hand.
      var remaining = Self.seconds
      while remaining > 0 {
        try? await Task.sleep(for: .milliseconds(250))
        if Task.isCancelled { return }
        if !hovering { remaining -= 0.25 }
      }
      dismiss()
    }
    .onAppear {
      AccessibilityNotification.Announcement(
        notice.isNew
          ? String(localized: "Saved to Places") : String(localized: "Already in Places")
      ).post()
    }
  }

  @ViewBuilder private var thumbnail: some View {
    ZStack {
      PalettePreview(palette: notice.place.palette)
      if let image = notice.image {
        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
      }
    }
    .frame(width: 44, height: 44)
    .clipShape(RoundedRectangle(cornerRadius: 7))
    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.2)))
    .accessibilityHidden(true)
  }
}

#if os(macOS)
  /// Flies a still of the canvas into the Places button, and makes the
  /// button answer.  The still travels in a transparent window of its own
  /// above the main one, since a view inside the window cannot cross its
  /// toolbar; that window takes no clicks, so the canvas under it stays live.
  @MainActor final class BookmarkFlightController: ObservableObject {
    /// How the Places button is answering.
    enum Response: Equatable {
      case rest
      /// The still is about to arrive: a little larger, and lit.
      case anticipating
      /// Lit without moving, for Reduce Motion and a place already saved.
      case highlighted
    }
    @Published private(set) var response = Response.rest
    weak var canvas: NSView?
    weak var places: NSView?
    private var window: NSWindow?
    private var generation = 0

    /// Flies `image` from the canvas to the Places button, or only lights
    /// the button when either is missing, as when the toolbar has hidden it
    /// in its overflow menu.
    func fly(_ image: CGImage) {
      guard let canvas, let places, let parent = canvas.window, places.window === parent,
        !places.isHiddenOrHasHiddenAncestor
      else {
        highlight()
        return
      }
      let flight = BookmarkFlight(
        from: rect(of: canvas, in: parent), to: rect(of: places, in: parent))
      finish()
      generation &+= 1
      let run = generation
      let child = NSWindow(
        contentRect: parent.frame, styleMask: .borderless, backing: .buffered, defer: false)
      child.isReleasedWhenClosed = false
      child.isOpaque = false
      child.backgroundColor = .clear
      child.hasShadow = false
      child.ignoresMouseEvents = true
      let host = NSHostingView(
        rootView: BookmarkFlightView(flight: flight, image: image, start: .now))
      host.frame = NSRect(origin: .zero, size: parent.frame.size)
      child.contentView = host
      child.setFrame(parent.frame, display: false)
      parent.addChildWindow(child, ordered: .above)
      window = child
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(BookmarkFlight.anticipation))
        guard run == generation else { return }
        withAnimation(.easeOut(duration: 0.12)) { response = .anticipating }
        try? await Task.sleep(for: .seconds(BookmarkFlight.duration - BookmarkFlight.anticipation))
        guard run == generation else { return }
        // One restrained rebound as it settles.
        withAnimation(.spring(duration: 0.32, bounce: 0.3)) { response = .rest }
        finish()
      }
    }

    /// Lights the Places button briefly, without motion.
    func highlight() {
      finish()
      generation &+= 1
      let run = generation
      withAnimation(.easeOut(duration: 0.15)) { response = .highlighted }
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(0.7))
        guard run == generation else { return }
        withAnimation(.easeIn(duration: 0.3)) { response = .rest }
      }
    }

    private func finish() {
      guard let window else { return }
      window.parent?.removeChildWindow(window)
      window.orderOut(nil)
      self.window = nil
    }

    /// A view's frame in its window, measured from the top left as SwiftUI
    /// measures, the title bar included.
    private func rect(of view: NSView, in window: NSWindow) -> CGRect {
      let frame = view.convert(view.bounds, to: nil)
      return CGRect(
        x: frame.minX, y: window.frame.height - frame.maxY, width: frame.width,
        height: frame.height)
    }
  }

  /// The travelling still: every frame read from `BookmarkFlight`.
  struct BookmarkFlightView: View {
    let flight: BookmarkFlight
    let image: CGImage
    let start: Date

    var body: some View {
      TimelineView(.animation) { context in
        still(at: context.date.timeIntervalSince(start))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .ignoresSafeArea()
    }

    /// Also drawn at fixed times by the storyboard preview.
    func still(at t: Double) -> some View {
      let frame = flight.frame(at: t)
      let lifted = min(1, max(0, t) / BookmarkFlight.lift)
      return Image(decorative: image, scale: 1)
        .resizable()
        .frame(width: frame.size.width, height: frame.size.height)
        .clipShape(RoundedRectangle(cornerRadius: frame.cornerRadius))
        .overlay(
          RoundedRectangle(cornerRadius: frame.cornerRadius)
            .strokeBorder(.white.opacity(0.85 * lifted), lineWidth: 1.5)
        )
        .shadow(
          color: .black.opacity(0.35 * frame.opacity), radius: frame.shadowRadius,
          y: frame.shadowRadius / 3
        )
        .rotationEffect(.degrees(frame.rotationDegrees))
        .opacity(frame.opacity)
        .position(frame.centre)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  /// Hands the view it sits behind to the flight, which measures it when
  /// it needs to.
  struct FlightAnchor: NSViewRepresentable {
    let attach: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
      let view = NSView()
      attach(view)
      return view
    }
    func updateNSView(_ view: NSView, context: Context) { attach(view) }
  }

  /// The Places toolbar button's label, which answers a flight.
  struct PlacesToolbarLabel: View {
    @ObservedObject var flight: BookmarkFlightController
    var body: some View {
      Label(ToolbarAction.places.title, systemImage: ToolbarAction.places.icon)
        .scaleEffect(flight.response == .anticipating ? 1.06 : 1)
        .brightness(flight.response == .rest ? 0 : 0.15)
        .foregroundStyle(flight.response == .rest ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
        .background(FlightAnchor { flight.places = $0 })
    }
  }
#endif

#if DEBUG
  @MainActor private func previewNotice(isNew: Bool) -> BookmarkNotice {
    let place = Location(
      name: "Near Seahorse Valley · 4,000×", real: "-0.743643887037151",
      imag: "0.13182590420533", scale: "4e3", palette: .ink)
    let image = NSImageOrUIImage.named("famous-1")
    return BookmarkNotice(place: place, isNew: isNew, image: image)
  }

  /// The preview thumbnails, by name, as a `CGImage` on either platform.
  enum NSImageOrUIImage {
    static func named(_ name: String) -> CGImage? {
      #if os(macOS)
        NSImage(named: name)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
      #else
        UIImage(named: name)?.cgImage
      #endif
    }
  }

  #Preview("Saved") {
    BookmarkNoticeCapsule(notice: previewNotice(isNew: true), undo: {}, name: {}, dismiss: {})
      .padding(40)
      .background(Color(red: 0.05, green: 0.15, blue: 0.35))
  }

  #Preview("Already saved") {
    BookmarkNoticeCapsule(notice: previewNotice(isNew: false), undo: {}, name: {}, dismiss: {})
      .padding(40)
      .background(Color(red: 0.05, green: 0.15, blue: 0.35))
  }

  #if os(macOS)
    /// The flight at eight instants, laid out like the design's storyboard:
    /// a mock window, its toolbar's Places button, and the still.
    private struct FlightStoryboard: View {
      let times: [Double] = [0, 0.06, 0.12, 0.22, 0.32, 0.40, 0.47, 0.52].map {
        $0 * BookmarkFlight.pace
      }
      let image = NSImageOrUIImage.named("famous-0")!
      var body: some View {
        let columns = Array(repeating: GridItem(.fixed(360), spacing: 16), count: 4)
        LazyVGrid(columns: columns, spacing: 16) {
          ForEach(times, id: \.self) { t in
            VStack(alignment: .leading, spacing: 4) {
              Text("\(Int(t * 1000)) ms").font(.headline)
              frame(at: t)
            }
          }
        }
        .padding(16)
      }
      func frame(at t: Double) -> some View {
        let size = CGSize(width: 360, height: 250)
        let toolbar: CGFloat = 40
        let places = CGRect(x: 290, y: 8, width: 24, height: 24)
        let flight = BookmarkFlight(
          from: CGRect(x: 0, y: toolbar, width: size.width, height: size.height - toolbar),
          to: places)
        let responding = t >= BookmarkFlight.anticipation
        return ZStack(alignment: .topLeading) {
          Image(decorative: image, scale: 1).resizable()
            .frame(width: size.width, height: size.height - toolbar)
            .offset(y: toolbar)
          Rectangle().fill(.bar).frame(height: toolbar)
          Image(systemName: ToolbarAction.places.icon)
            .foregroundStyle(responding ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .scaleEffect(responding && t < BookmarkFlight.duration ? 1.06 : 1)
            .frame(width: places.width, height: places.height)
            .offset(x: places.minX, y: places.minY)
          BookmarkFlightView(flight: flight, image: image, start: .now).still(at: t)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
      }
    }

    #Preview("Flight storyboard") {
      FlightStoryboard()
    }
  #endif
#endif
