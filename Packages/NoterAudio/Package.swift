// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NoterAudio",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "NoterAudio", targets: ["NoterAudio"])
    ],
    targets: [
        .target(name: "NoterAudio"),
        .testTarget(name: "NoterAudioTests", dependencies: ["NoterAudio"])
    ]
)
