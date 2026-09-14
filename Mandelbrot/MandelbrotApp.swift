//
//  MandelbrotApp.swift
//  Mandelbrot
//
//  Created by Jules Bean on 19/01/2026.
//

import SwiftUI
import Darwin

@main
enum MandelbrotMain {
    @MainActor static func main() async {
        #if os(macOS)
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--benchmark") || arguments.contains("--render") || arguments.contains("--help") {
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
    }
}
