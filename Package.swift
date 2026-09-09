// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HotCopyist",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "HotCopyist",
            path: "Sources/HotCopyist"
        )
    ]
)
