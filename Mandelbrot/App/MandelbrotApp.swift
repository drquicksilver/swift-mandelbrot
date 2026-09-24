// The entry point.  On the Mac a command-line flag (--render, --benchmark,
// --movie, --test-tiles and the other diagnostics) runs a headless tool and
// exits before SwiftUI starts, which is how `make test` and the benchmarks drive
// the real renderers.  Otherwise it opens explorer windows, their menu commands
// and, on the Mac, the developer window.

import Darwin
import SwiftUI

@main
enum MandelbrotMain {
  @MainActor static func main() async {
    #if os(macOS)
      let arguments = Array(CommandLine.arguments.dropFirst())
      if let index = arguments.firstIndex(of: "--test-bla") {
        guard index + 1 < arguments.count else {
          FileHandle.standardError.write(Data("--test-bla requires a fixture JSON path\n".utf8))
          exit(2)
        }
        exit(await BLADiagnostics.run(fixture: arguments[index + 1]))
      }
      if arguments.contains("--benchmark-reference") {
        exit(await TileDiagnostics.runReferenceBenchmark())
      }
      if arguments.contains("--test-tiles") { exit(await TileDiagnostics.run()) }
      if arguments.contains("--benchmark-compositor") {
        exit(await TileDiagnostics.runCompositorBenchmark())
      }
      if arguments.contains("--benchmark") || arguments.contains("--render")
        || arguments.contains("--movie") || arguments.contains("--help")
      {
        exit(await BenchmarkCLI.run(arguments: arguments))
      }
    #endif
    MandelbrotApp.main()
  }
}

struct MandelbrotApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView()
    }
    .commands { ExplorerCommands() }
    #if os(macOS)
      Window("Developer", id: DeveloperWindow.id) { DeveloperWindow() }
        .defaultSize(width: 480, height: 440)
    #endif
  }
}
