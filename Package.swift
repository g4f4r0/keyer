// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Keyer",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "WaveCore", targets: ["WaveCore"]),
        .executable(name: "Keyer", targets: ["Keyer"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "WaveCore"),
        .executableTarget(
            name: "Keyer",
            dependencies: ["WaveCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(name: "WaveCoreTests", dependencies: ["WaveCore"]),
    ],
    swiftLanguageModes: [.v6]
)
