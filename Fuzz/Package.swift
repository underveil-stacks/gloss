// swift-tools-version: 6.0
import PackageDescription

// Fuzz targets for the code that takes hostile input. Built only by
// scripts/fuzz.sh, which adds the fuzzer and address sanitizer.
let package = Package(
    name: "GlossFuzz",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../Packages/GlossCore")],
    targets: [
        .executableTarget(name: "SanitizerFuzz", dependencies: ["GlossCore"]),
        .executableTarget(name: "RenderFuzz", dependencies: ["GlossCore"]),
    ]
)
