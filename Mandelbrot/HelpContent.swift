import SwiftUI

/// The toolbar's buttons, defined once: the button itself, its tooltip, and its
/// row in the help all come from here, so a button cannot appear without an
/// explanation.
enum ToolbarAction: String, CaseIterable, Identifiable {
  case reset, upright, back, forward, places, bookmark, julia, movie, share, settings, help
  var id: String { rawValue }
  var icon: String {
    switch self {
    case .reset: return "house"
    case .upright: return "location.north.line"
    case .back: return "chevron.backward"
    case .forward: return "chevron.forward"
    case .places: return "bookmark"
    case .bookmark: return "bookmark.fill"
    case .julia: return "circle.lefthalf.filled"
    case .movie: return "film"
    case .share: return "square.and.arrow.up"
    case .settings: return "slider.horizontal.3"
    case .help: return "questionmark.circle"
    }
  }
  var title: String {
    switch self {
    case .reset: return "Reset"
    case .upright: return "Upright"
    case .back: return "Back"
    case .forward: return "Forward"
    case .places: return "Places"
    case .bookmark: return "Bookmark"
    case .julia: return "Julia Companion"
    case .movie: return "Zoom Movie"
    case .share: return "Share"
    case .settings: return "Settings"
    case .help: return "Controls"
    }
  }
  /// The tooltip, and the sentence beside the icon in the help.
  var explanation: String {
    switch self {
    case .reset: return "Go back to the whole set."
    case .upright: return "Turn the view back to upright. It appears once the view is rotated."
    case .back: return "Return to the last place you looked at."
    case .forward: return "Go forward again after going back."
    case .places: return "Open the gallery of places, and the views you have bookmarked."
    case .bookmark: return "Keep this view in Places, under a name of your choosing."
    case .julia:
      return "Show the Julia companion beside the view, with a crosshair marking its point."
    case .movie: return "Render a zoom from a starting place down to this view, and save it."
    case .share: return "Copy a link to this exact view, rotation, palette and detail."
    case .settings: return "Palette, colour spacing, detail, and how the companion behaves."
    case .help: return "The gestures, the buttons and the keyboard shortcuts."
    }
  }
  /// The keyboard shortcut that does the same thing, where there is one.
  var command: ExplorerCommand? {
    switch self {
    case .reset: return .reset
    case .upright: return .resetRotation
    case .back: return .back
    case .forward: return .forward
    case .places: return .places
    case .bookmark: return .bookmark
    case .julia: return .julia
    case .movie: return .movie
    case .share: return nil
    case .settings: return nil
    case .help: return .help
    }
  }
}

/// One line of the help: an icon and a sentence.  One idea per row, because the
/// run-on paragraph this replaced read as though a plain drag framed a region.
struct HelpLine: Identifiable {
  let icon: String
  let text: String
  var id: String { text }
}

enum HelpContent {
  /// The gestures, which are the main content: what the hands do, one per line.
  static var gestures: [HelpLine] {
    #if os(macOS)
      return [
        HelpLine(icon: "hand.draw", text: "Drag to move around."),
        HelpLine(
          icon: "rectangle.dashed", text: "Hold Shift and drag to frame a region to zoom into."),
        HelpLine(
          icon: "magnifyingglass",
          text: "Scroll, or pinch on a trackpad, to zoom at the pointer."),
        HelpLine(icon: "cursorarrow.click.2", text: "Double-click to zoom in one step."),
        HelpLine(
          icon: "rotate.right",
          text: "Twist with two fingers to rotate; it snaps upright near a right angle."),
        HelpLine(
          icon: "plus.magnifyingglass",
          text: "Drag the crosshair to move the companion's point, or click it to pin it."),
      ]
    #else
      return [
        HelpLine(icon: "hand.draw", text: "Drag to move around."),
        HelpLine(icon: "magnifyingglass", text: "Pinch to zoom around your fingers."),
        HelpLine(icon: "hand.tap", text: "Double-tap to zoom in one step."),
        HelpLine(icon: "hand.point.up.left", text: "Tap with two fingers to zoom out one step."),
        HelpLine(icon: "rotate.right", text: "Twist with two fingers to rotate the view."),
        HelpLine(
          icon: "plus.magnifyingglass",
          text: "Drag the crosshair to move the companion's point, or tap it to pin it."),
      ]
    #endif
  }
  /// What the view does on its own, rather than what the hands do.
  static var behaviour: [HelpLine] {
    [
      HelpLine(icon: "sparkle", text: "Finer detail appears as you explore."),
      HelpLine(
        icon: "exclamationmark.circle",
        text: "A notice appears when you reach the current precision limit."),
    ]
  }
  static var toolbar: [ToolbarAction] { ToolbarAction.allCases }
  /// The shortcuts, last, and only where there is a keyboard to press.
  static var keyboard: [ExplorerCommand] {
    ExplorerCommand.allCases.filter { $0 != .benchmark }
  }
  static func showsKeyboard(hardwareKeyboard: Bool) -> Bool {
    #if os(macOS)
      return true
    #else
      return hardwareKeyboard
    #endif
  }
}
