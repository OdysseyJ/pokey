// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pokey",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Pokey", path: "Sources/Pokey")
    ]
)
