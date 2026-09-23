import SwiftUI

enum ExplorerCommand: String, CaseIterable, Identifiable {
  case reset, zoomIn, zoomOut, left, right, up, down, increaseIterations, decreaseIterations,
    rotateLeft, rotateRight, resetRotation, back, forward, places, bookmark, julia, swapJulia,
    movie, benchmark, help
  var id: String { rawValue }
  var title: String {
    switch self {
    case .reset: return String(localized: "Reset View")
    case .zoomIn: return String(localized: "Zoom In")
    case .zoomOut: return String(localized: "Zoom Out")
    case .left: return String(localized: "Move Left")
    case .right: return String(localized: "Move Right")
    case .up: return String(localized: "Move Up")
    case .down: return String(localized: "Move Down")
    case .increaseIterations: return String(localized: "Increase Detail")
    case .decreaseIterations: return String(localized: "Decrease Detail")
    case .rotateLeft: return String(localized: "Rotate Left")
    case .rotateRight: return String(localized: "Rotate Right")
    case .resetRotation: return String(localized: "Upright")
    case .back: return String(localized: "Back")
    case .forward: return String(localized: "Forward")
    case .places: return String(localized: "Places")
    case .bookmark: return String(localized: "Bookmark This View")
    case .julia: return String(localized: "Julia Companion")
    case .swapJulia: return String(localized: "Swap Main and Companion")
    case .movie: return String(localized: "Zoom Movie…")
    case .benchmark: return String(localized: "Benchmarks")
    case .help: return String(localized: "Controls")
    }
  }
  var key: KeyEquivalent {
    switch self {
    // ⌘0, the Mac's usual return to actual size.
    case .reset: return "0"
    case .zoomIn: return "+"
    case .zoomOut: return "-"
    case .left: return .leftArrow
    case .right: return .rightArrow
    case .up: return .upArrow
    case .down: return .downArrow
    case .increaseIterations: return "]"
    case .decreaseIterations: return "["
    case .rotateLeft: return ","
    case .rotateRight: return "."
    case .resetRotation: return "u"
    case .back: return .leftArrow
    case .forward: return .rightArrow
    case .places: return "l"
    case .bookmark: return "d"
    case .julia: return "j"
    case .swapJulia: return "j"
    case .movie: return "m"
    case .benchmark: return "b"
    case .help: return "?"
    }
  }
  var modifiers: EventModifiers {
    switch self {
    case .left, .right, .up, .down: return []
    case .back, .forward: return [.command, .shift]
    case .swapJulia: return [.command, .shift]
    // A bare "?", which the canvas answers: Command-? belongs to the system's
    // Help search, and a menu drops a "?" equivalent.
    case .help: return []
    // Command-comma belongs to Settings, so twisting takes Shift as well.
    case .rotateLeft, .rotateRight: return [.command, .shift]
    default: return [.command]
    }
  }
  var binding: String {
    switch self {
    case .reset: return "⌘ 0"
    case .zoomIn: return "⌘ +"
    case .zoomOut: return "⌘ −"
    case .left: return "←"
    case .right: return "→"
    case .up: return "↑"
    case .down: return "↓"
    case .increaseIterations: return "⌘ ]"
    case .decreaseIterations: return "⌘ ["
    case .rotateLeft: return "⌘ ⇧ ,"
    case .rotateRight: return "⌘ ⇧ ."
    case .resetRotation: return "⌘ U"
    case .back: return "⌘ ⇧ ←"
    case .forward: return "⌘ ⇧ →"
    case .places: return "⌘ L"
    case .bookmark: return "⌘ D"
    case .julia: return "⌘ J"
    case .swapJulia: return "⌘ ⇧ J"
    case .movie: return "⌘ M"
    case .benchmark: return "⌘ B"
    case .help: return "?"
    }
  }
  /// The Explore menu, in the groups a Mac menu separates: where you are,
  /// zoom, movement, rotation, detail, places, the companion, the movie.
  /// Controls lives in the Help menu instead.
  static let menuGroups: [[ExplorerCommand]] = [
    [.back, .forward, .reset],
    [.zoomIn, .zoomOut],
    [.left, .right, .up, .down],
    [.rotateLeft, .rotateRight, .resetRotation],
    [.increaseIterations, .decreaseIterations],
    [.places, .bookmark],
    [.julia, .swapJulia],
    [.movie],
  ]
  /// The bare keys are the canvas's own.  As menu shortcuts they would fire
  /// from anywhere in the window, a text field in a sheet included, so the
  /// menu lists these without binding them.
  var bindsInMenu: Bool { modifiers.contains(.command) }
}

#if os(macOS)
  import AppKit
  import Combine
  @MainActor final class DeveloperAccess: ObservableObject {
    static let shared = DeveloperAccess()
    @Published var optionHeld = false
    private var monitor: Any?
    private init() {
      monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
        Task { @MainActor in
          DeveloperAccess.shared.optionHeld = event.modifierFlags.contains(.option)
        }
        return event
      }
    }
  }
#endif
struct ExplorerCommands: Commands {
  #if os(macOS)
    @ObservedObject private var access = DeveloperAccess.shared
    @AppStorage("DeveloperMenuEnabled") private var developerMenu = false
  #endif
  /// Observed, not merely read: a menu item's enabled state has to follow
  /// the model as it changes, not only when the focused window does.
  @FocusedObject private var explorer: ExplorerModel?
  var body: some Commands {
    // Settings is still a sheet on the window it changes, so the standard
    // command opens that sheet rather than a separate Settings scene.
    CommandGroup(replacing: .appSettings) {
      Button("Settings…") { explorer?.showSettings = true }
        .keyboardShortcut(",", modifiers: .command)
        .disabled(explorer?.isPresentingSheet ?? true)
    }
    CommandMenu("Explore") {
      ForEach(Array(ExplorerCommand.menuGroups.enumerated()), id: \.offset) { index, group in
        if index > 0 { Divider() }
        ForEach(group) { command in item(command) }
      }
    }
    CommandGroup(replacing: .help) { item(.help) }
    #if os(macOS)
      if access.optionHeld || developerMenu {
        CommandMenu("Debug") {
          Button("Developer Panel") { explorer?.showDeveloper = true }
          Button(ExplorerCommand.benchmark.title) { explorer?.perform(.benchmark) }
            .keyboardShortcut(
              ExplorerCommand.benchmark.key, modifiers: ExplorerCommand.benchmark.modifiers)
        }
      }
    #endif
  }

  @ViewBuilder private func item(_ command: ExplorerCommand) -> some View {
    let button = Button(command.title) { explorer?.perform(command) }
      .disabled(!(explorer?.canPerform(command) ?? false))
    if command.bindsInMenu {
      button.keyboardShortcut(command.key, modifiers: command.modifiers)
    } else {
      button
    }
  }
}

#if os(macOS)
  extension ExplorerCommand {
    static func matching(_ event: NSEvent) -> ExplorerCommand? {
      let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
      for command in ExplorerCommand.allCases where command != .benchmark {
        var expected = NSEvent.ModifierFlags()
        if command.modifiers.contains(.command) { expected.insert(.command) }
        if command.modifiers.contains(.shift) { expected.insert(.shift) }
        let arrow: [ExplorerCommand: UInt16] = [
          .left: 123, .right: 124, .down: 125, .up: 126, .back: 123, .forward: 124,
        ]
        // "?" is Shift-/ on most layouts, so help never compares the Shift
        // that typing it needs.
        if command == .help {
          if event.characters == "?" && flags.subtracting(.shift).isEmpty {
            return command
          }
          continue
        }
        let matches =
          arrow[command] == event.keyCode
          || event.charactersIgnoringModifiers?.lowercased()
            == String(command.key.character).lowercased()
        if matches && flags == expected {
          return command
        }
      }
      return nil
    }
  }
#endif
