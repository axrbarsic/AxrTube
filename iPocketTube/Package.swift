// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "iPocketTube",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
    ],
    products: [
        // Cross-platform core: models + InnerTube/SponsorBlock services (Foundation only).
        .library(
            name: "iPocketTubeCore",
            targets: ["iPocketTubeCore"]
        ),
        // SwiftUI UI layer (iOS/iPadOS/macOS).
        .library(name: "iPocketTube", targets: ["iPocketTube"]),
    ],
    dependencies: [],
    targets: [
        // MARK: Core – iOS, macOS (Foundation only)
        .target(
            name: "iPocketTubeCore",
            dependencies: [],
            path: "Sources/iPocketTubeCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // MARK: UI – iOS/iPadOS/macOS (SwiftUI)
        .target(
            name: "iPocketTube",
            dependencies: [
                "iPocketTubeCore",
            ],
            path: "Sources/iPocketTube",
            exclude: [
                "translate_strings.py",
            ],
            resources: [
                .process("Localizable.xcstrings"),
                .copy("Resources/yt.solver.lib.min.js"),
                .copy("Resources/yt.solver.core.min.js"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // MARK: Tests
        .testTarget(
            name: "iPocketTubeTests",
            dependencies: ["iPocketTubeCore", "iPocketTube"],
            path: "Tests/iPocketTubeTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
