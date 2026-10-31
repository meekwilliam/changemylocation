// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "changemylocation",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "changemylocation", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
