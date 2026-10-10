// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BeatKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "BeatKit", targets: ["BeatKit"]),
    ],

    targets: [
        .target(name: "BeatKit"),
        // Offline harness: runs the real-time tracker over an audio file (or synthetic music)
        // exactly as the app's scheduler would, and can render the counts mixed into a WAV.
        .executableTarget(name: "beatcli", dependencies: ["BeatKit"]),
        .testTarget(name: "BeatKitTests", dependencies: ["BeatKit"]),
    ],
    swiftLanguageModes: [.v5]
)
