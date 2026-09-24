// Every shortcut the help lists reaches its command on this platform.

import SwiftUI
import Testing

@testable import Mandelbrot

#if os(macOS)
  import AppKit
#endif

/// Help lists every shortcut in `HelpContent.keyboard`.  Each must reach a
/// command on this platform: through the menu, which binds it, or through the
/// canvas, which must recognise the key.  Stage 5 of 2.12 moved the bare keys
/// to the canvas on both platforms, and the iPad, which has no canvas key
/// handler, silently lost them.
struct KeyboardTests {
  @Test func everyListedShortcutHasALiveBinding() {
    for command in HelpContent.keyboard {
      switch command.keyRoute {
      case .menu:
        // A menu drops a "?" equivalent without a word.
        #expect(command.key.character != "?", "\(command) needs a key a menu will carry")
        #if os(macOS)
          // A bare key in a Mac menu would fire from a sheet's text field.
          #expect(command.modifiers.contains(.command), "\(command) is a bare key in the menu")
        #endif
      case .canvas:
        #if os(macOS)
          #expect(
            ExplorerCommand.matching(Self.press(command)) == command,
            "The canvas does not hear \(command)")
        #else
          Issue.record("\(command) is routed to a canvas that has no key handler")
        #endif
      }
    }
  }

  #if os(macOS)
    /// The key press a person makes for a command.
    static func press(_ command: ExplorerCommand) -> NSEvent {
      let arrows: [Character: UInt16] = [
        Character(UnicodeScalar(NSLeftArrowFunctionKey)!): 123,
        Character(UnicodeScalar(NSRightArrowFunctionKey)!): 124,
        Character(UnicodeScalar(NSDownArrowFunctionKey)!): 125,
        Character(UnicodeScalar(NSUpArrowFunctionKey)!): 126,
      ]
      let character = command.key.character
      var flags = NSEvent.ModifierFlags()
      if command.modifiers.contains(.command) { flags.insert(.command) }
      if command.modifiers.contains(.shift) || character == "?" { flags.insert(.shift) }
      return NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: String(character), charactersIgnoringModifiers: String(character),
        isARepeat: false, keyCode: arrows[character] ?? 0)!
    }
  #endif
}
