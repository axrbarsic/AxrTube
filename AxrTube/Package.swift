// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "iPocketTube",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v26),
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
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.5"
        ),
        .package(
            url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git",
            from: "1.16.0"
        ),
    ],
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
                .product(
                    name: "FluidAudio",
                    package: "FluidAudio",
                    condition: .when(platforms: [.iOS])
                ),
                .product(
                    name: "onnxruntime",
                    package: "onnxruntime-swift-package-manager",
                    condition: .when(platforms: [.iOS])
                ),
            ],
            path: "Sources/iPocketTube",
            exclude: [
                "translate_strings.py",
            ],
            resources: [
                .process("Localizable.xcstrings"),
                .process("Resources/AppIconPreviews"),
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
            resources: [
                .copy("Fixtures/progressive-audio.m4a"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
