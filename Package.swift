// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ccbench",
    platforms: [.macOS(.v13)],
    products: [
        // Embeddable SDK: a macOS app (or any Swift host) depends on this.
        .library(name: "CCBenchKit", targets: ["CCBenchKit"]),
        // Thin CLI over the same library (`swift run ccbench …`).
        .executable(name: "ccbench", targets: ["ccbench"]),
    ],
    dependencies: [
        // Yams parses the per-task judge-rubric front-matter.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "CCBenchKit",
            dependencies: ["Yams"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ccbench",
            dependencies: [
                "CCBenchKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CCBenchKitTests",
            dependencies: ["CCBenchKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
