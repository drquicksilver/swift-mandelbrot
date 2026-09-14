import SwiftUI

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Explore") {
                    Text("Drag to move. Pinch to zoom around your fingers.")
                    Text("Finer detail appears as you explore. A small notice appears when you reach the current precision limit.")
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
