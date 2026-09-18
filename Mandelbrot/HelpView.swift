import SwiftUI

#if os(iOS)
  import GameController
#endif

/// The controls, built around the toolbar's own icons: the gestures first,
/// because they are what the app is mostly used with, then a row for every
/// button, then the keyboard shortcuts -- and those only where there is a
/// keyboard to press them on.
struct HelpView: View {
  @Environment(\.dismiss) private var dismiss
  #if os(iOS)
    @State private var hardwareKeyboard = GCKeyboard.coalesced != nil
  #else
    private let hardwareKeyboard = true
  #endif
  var body: some View {
    NavigationStack {
      List {
        Section("Explore") {
          ForEach(HelpContent.gestures) { line in
            Label(line.text, systemImage: line.icon)
          }
        }
        Section {
          ForEach(HelpContent.behaviour) { line in
            Label(line.text, systemImage: line.icon)
          }
        }
        Section("Buttons") {
          ForEach(HelpContent.toolbar) { action in
            HStack(alignment: .firstTextBaseline) {
              Label {
                VStack(alignment: .leading, spacing: 2) {
                  Text(action.title)
                  Text(action.explanation).font(.caption).foregroundStyle(.secondary)
                }
              } icon: {
                Image(systemName: action.icon)
              }
              if hardwareKeyboard, let command = action.command {
                Spacer()
                Text(command.binding).font(.caption.monospaced()).foregroundStyle(.secondary)
              }
            }
          }
        }
        if HelpContent.showsKeyboard(hardwareKeyboard: hardwareKeyboard) {
          Section("Keyboard") {
            ForEach(HelpContent.keyboard) { command in
              LabeledContent(command.title, value: command.binding)
            }
          }
        }
      }.navigationTitle("Controls")
        .toolbar { Button("Done") { dismiss() } }
    }.frame(minWidth: 300, idealWidth: 440, minHeight: 350)
      #if os(iOS)
        // A keyboard can arrive or leave while the window is open.
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in
          hardwareKeyboard = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in
          hardwareKeyboard = GCKeyboard.coalesced != nil
        }
      #endif
  }
}
