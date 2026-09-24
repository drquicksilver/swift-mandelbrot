// swift-tools-version: 6.2
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
