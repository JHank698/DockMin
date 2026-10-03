// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DockMin",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "DockMin",
            path: "Sources/DockMin"
        )
    ]
)
