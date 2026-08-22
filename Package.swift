// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Keyer",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "WaveCore", targets: ["WaveCore"]),
        .executable(name: "Keyer", targets: ["Keyer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6"),
    ],
    targets: [
        .target(name: "WaveCore"),
        .executableTarget(
            name: "Keyer",
            dependencies: [
                "WaveCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(name: "WaveCoreTests", dependencies: ["WaveCore"]),
    ],
    swiftLanguageModes: [.v6]
)
