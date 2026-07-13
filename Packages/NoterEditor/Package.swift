// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NoterEditor",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "NoterEditor", targets: ["NoterEditor"])
    ],
    targets: [
        .target(name: "NoterEditor"),
        .testTarget(name: "NoterEditorTests", dependencies: ["NoterEditor"])
    ]
)
