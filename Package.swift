// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MandelbrotCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "MandelbrotCore", targets: ["MandelbrotCore"])],
    targets: [
        .target(name: "MandelbrotCore", path: "Mandelbrot/Core"),
        .testTarget(name: "MandelbrotCoreTests", dependencies: ["MandelbrotCore"], path: "tests/CoreTests")
    ],
    swiftLanguageModes: [.v5]
)
