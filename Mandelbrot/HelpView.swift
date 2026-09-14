import SwiftUI

struct HelpView: View {
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      List {
        Section("Explore") {
          #if os(macOS)
            Text(
              "Drag to move. Scroll or pinch to zoom at the pointer. Double-click to zoom in. Shift-drag to frame a region."
            )
          #else
            Text(
              "Drag to move. Pinch around your fingers to zoom. Double-tap to zoom in; tap with two fingers to zoom out."
            )
          #endif
          Text(
            "Finer detail appears as you explore. A small notice appears when you reach the current precision limit."
          )
        }
        #if os(macOS)
          Section("Keyboard") {
            ForEach(ExplorerCommand.allCases.filter { $0 != .benchmark }) { command in
              LabeledContent(command.title, value: command.binding)
            }
          }
        #endif
      }.navigationTitle("Controls")
        .toolbar { Button("Done") { dismiss() } }
    }.frame(minWidth: 300, idealWidth: 440, minHeight: 350)
  }
}
