// The words of the help, kept as data: each toolbar button's icon, title and
// explanation (also its tooltip), and the gestures, written per platform as
// whole sentences so each translates cleanly (see docs/Glossary.md).

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
    // Two commands, two shapes: a library for Places, a bookmark for
    // bookmarking.  An outline and a filled bookmark read as one toggle.
    case .places: return "books.vertical"
    case .bookmark: return "bookmark"
    case .julia: return "circle.lefthalf.filled"
    case .movie: return "film"
    case .share: return "square.and.arrow.up"
    case .settings: return "slider.horizontal.3"
    case .help: return "questionmark.circle"
    }
  }
  var title: String {
    switch self {
    case .reset: return String(localized: "Reset")
    case .upright: return String(localized: "Upright")
    case .back: return String(localized: "Back")
    case .forward: return String(localized: "Forward")
    case .places: return String(localized: "Places")
    case .bookmark: return String(localized: "Bookmark")
    case .julia: return String(localized: "Julia Companion")
    case .movie: return String(localized: "Zoom Movie")
    case .share: return String(localized: "Share")
    case .settings: return String(localized: "Settings")
    case .help: return String(localized: "Controls")
    }
  }
  /// The tooltip, and the sentence beside the icon in the help.
  var explanation: String {
    switch self {
    case .reset: return String(localized: "Go back to the whole set.")
    case .upright:
      return String(
        localized: "Turn the view back to upright after rotating it.")
    case .back: return String(localized: "Return to the last place you looked at.")
    case .forward: return String(localized: "Go forward again after going back.")
    case .places: return String(localized: "Open the famous places and your bookmarks.")
    case .bookmark: return String(localized: "Bookmark this view, so it is waiting in Places.")
    case .julia:
      return String(
        localized: "Show the Julia companion beside the view, with a crosshair marking its point.")
    case .movie:
      return String(localized: "Render a movie of the journey from a place to this view.")
    case .share:
      return String(
        localized: "Share a link to this exact view, with its rotation, palette and detail.")
    case .settings:
      return String(localized: "Palette, colour spacing, detail, and how the companion behaves.")
    case .help: return String(localized: "The gestures, the buttons and the keyboard shortcuts.")
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
        HelpLine(icon: "hand.draw", text: String(localized: "Drag to move around.")),
        HelpLine(
          icon: "rectangle.dashed",
          text: String(localized: "Hold Shift and drag to frame a region to zoom into.")),
        HelpLine(
          icon: "magnifyingglass",
          text: String(localized: "Scroll, or pinch on a trackpad, to zoom at the pointer.")),
        HelpLine(
          icon: "cursorarrow.click.2",
          text: String(localized: "Double-click to zoom in one step; hold Option to zoom out.")),
        HelpLine(
          icon: "rotate.right",
          text: String(
            localized: "Twist with two fingers to rotate; it snaps upright near a right angle.")),
        HelpLine(
          icon: "plus.magnifyingglass",
          text: String(
            localized: "Drag the crosshair to move the companion's point, or click it to pin it.")),
      ]
    #else
      return [
        HelpLine(icon: "hand.draw", text: String(localized: "Drag to move around.")),
        HelpLine(
          icon: "magnifyingglass", text: String(localized: "Pinch to zoom around your fingers.")),
        HelpLine(icon: "hand.tap", text: String(localized: "Double-tap to zoom in one step.")),
        HelpLine(
          icon: "hand.point.up.left",
          text: String(localized: "Tap with two fingers to zoom out one step.")),
        HelpLine(
          icon: "rotate.right",
          text: String(localized: "Twist with two fingers to rotate the view.")),
        HelpLine(
          icon: "plus.magnifyingglass",
          text: String(
            localized: "Drag the crosshair to move the companion's point, or tap it to pin it.")),
      ]
    #endif
  }
  /// What the view does on its own, rather than what the hands do.
  static var behaviour: [HelpLine] {
    [
      HelpLine(icon: "sparkle", text: String(localized: "Finer detail appears as you explore.")),
      HelpLine(
        icon: "exclamationmark.circle",
        text: String(
          localized: "A notice appears when you reach the deepest zoom the app can draw.")),
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
