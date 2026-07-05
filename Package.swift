// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CopyWiz",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "CopyWiz",
            path: "Sources/CopyWiz"
        )
    ]
)
