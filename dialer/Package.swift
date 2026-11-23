// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClarityDialer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ClarityDialer", path: "Sources/ClarityDialer"),
        .testTarget(name: "ClarityDialerTests", dependencies: ["ClarityDialer"], path: "Tests/ClarityDialerTests"),
    ]
)
