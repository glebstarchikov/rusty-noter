// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NoterCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "NoterCore", targets: ["NoterCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0")
    ],
    targets: [
        .target(
            name: "NoterCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Yams", package: "Yams")
            ]
        ),
        .testTarget(name: "NoterCoreTests", dependencies: ["NoterCore"])
    ]
)
