// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GlossCore",
    // Lower than the app, so the core can be built and analysed on hosted runners.
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GlossCore", targets: ["GlossCore"])
    ],
    dependencies: [
        // cmark-gfm, the parser GitHub uses, as packaged by the Swift project.
        .package(url: "https://github.com/swiftlang/swift-cmark", exact: "0.9.0")
    ],
    targets: [
        .target(
            name: "GlossCore",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ]
        ),
        .testTarget(name: "GlossCoreTests", dependencies: ["GlossCore"]),
    ]
)
