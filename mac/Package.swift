// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClarityLiveCoach",
    platforms: [.macOS("14.4")], // Core Audio process taps need macOS 14.4+
    targets: [
        .executableTarget(name: "ClarityLiveCoach", path: "Sources/ClarityLiveCoach")
    ]
)
