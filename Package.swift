// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SilenceCut",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SilenceCutCore", targets: ["SilenceCutCore"]),
        .executable(name: "silencecut", targets: ["silencecut"]),
    ],
    targets: [
        .target(name: "SilenceCutCore", path: "Sources/SilenceCutCore"),
        .executableTarget(name: "silencecut", dependencies: ["SilenceCutCore"], path: "Sources/silencecut"),
        .testTarget(name: "SilenceCutCoreTests", dependencies: ["SilenceCutCore"], path: "Tests/SilenceCutCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
