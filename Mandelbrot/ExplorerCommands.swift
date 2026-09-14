import SwiftUI

enum ExplorerCommand: String, CaseIterable, Identifiable {
    case reset, zoomIn, zoomOut, left, right, up, down, increaseIterations, decreaseIterations, benchmark, help
    var id: String { rawValue }
    var title: String {
        switch self {
        case .reset: return "Reset View"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .left: return "Move Left"
        case .right: return "Move Right"
        case .up: return "Move Up"
        case .down: return "Move Down"
        case .increaseIterations: return "Increase Detail"
        case .decreaseIterations: return "Decrease Detail"
        case .benchmark: return "Benchmarks"
        case .help: return "Controls"
        }
    }
    var key: KeyEquivalent {
        switch self {
        case .reset: return "h"
        case .zoomIn: return "+"
        case .zoomOut: return "-"
        case .left: return .leftArrow
        case .right: return .rightArrow
        case .up: return .upArrow
        case .down: return .downArrow
        case .increaseIterations: return "]"
        case .decreaseIterations: return "["
        case .benchmark: return "b"
        case .help: return "/"
        }
    }
    var modifiers: EventModifiers {
        switch self {
        case .left, .right, .up, .down: return []
        case .reset, .help: return [.shift]
        default: return [.command]
        }
    }
    var binding: String {
        switch self {
        case .reset: return "Shift H"
        case .zoomIn: return "⌘ +"
        case .zoomOut: return "⌘ −"
        case .left: return "←"
        case .right: return "→"
        case .up: return "↑"
        case .down: return "↓"
        case .increaseIterations: return "⌘ ]"
        case .decreaseIterations: return "⌘ ["
        case .benchmark: return "⌘ B"
        case .help: return "?"
        }
    }
}

struct ExplorerFocusKey: FocusedValueKey { typealias Value = ExplorerModel }
extension FocusedValues {
    var explorer: ExplorerModel? {
        get { self[ExplorerFocusKey.self] }
        set { self[ExplorerFocusKey.self] = newValue }
    }
}
#if os(macOS)
import AppKit
import Combine
@MainActor final class DeveloperAccess: ObservableObject {
    static let shared = DeveloperAccess()
    @Published var optionHeld = false
    private var monitor: Any?
    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching:.flagsChanged) { event in
            Task { @MainActor in DeveloperAccess.shared.optionHeld = event.modifierFlags.contains(.option) }
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
    @FocusedValue(\.explorer) private var explorer
    var body: some Commands {
        CommandMenu("Explore") {
            ForEach(ExplorerCommand.allCases.filter { $0 != .benchmark }) { command in
                Button(command.title) { explorer?.perform(command) }
                    .keyboardShortcut(command.key, modifiers: command.modifiers)
            }
        }
        #if os(macOS)
        if access.optionHeld || developerMenu {
            CommandMenu("Debug") {
                Button("Developer Panel") { explorer?.showDeveloper = true }
                Button(ExplorerCommand.benchmark.title) { explorer?.perform(.benchmark) }
                    .keyboardShortcut(ExplorerCommand.benchmark.key,modifiers:ExplorerCommand.benchmark.modifiers)
            }
        }
        #endif
    }
}
