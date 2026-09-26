// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "meepmeep",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "meepmeep",
            path: "Sources/meepmeep",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
