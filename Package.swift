// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TubeTunes",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "TubeTunes", path: "Sources/TubeTunes")
    ]
)
