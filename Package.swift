// swift-tools-version: 6.2
// Mandelbrot/Core as a Swift package, so its platform-independent mathematics
// can be unit tested with `swift test` (tests/core) without building the app.
// The app compiles the same files directly; this package is not a dependency.
import PackageDescription

let package = Package(
  name: "MandelbrotCore",
  platforms: [.macOS(.v15), .iOS(.v18)],
  products: [.library(name: "MandelbrotCore", targets: ["MandelbrotCore"])],
  targets: [
    .target(
      name: "MandelbrotCore", path: "Mandelbrot/Core",
      exclude: ["Vendor/BigInt/LICENSE.md", "Vendor/BigInt/PROVENANCE.md"]),
    .testTarget(
      name: "MandelbrotCoreTests", dependencies: ["MandelbrotCore"], path: "tests/core"),
  ],
  swiftLanguageModes: [.v5]
)
