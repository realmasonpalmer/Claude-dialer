// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClarityLiveCoach",
    platforms: [.macOS("14.4")], // Core Audio process taps need macOS 14.4+
    targets: [
        .target(name: "CoachCore", path: "Sources/CoachCore"),
        .executableTarget(name: "ClarityLiveCoach", dependencies: ["CoachCore"], path: "Sources/ClarityLiveCoach"),
        .testTarget(name: "CoachCoreTests", dependencies: ["CoachCore"], path: "Tests/CoachCoreTests")
    ]
)
