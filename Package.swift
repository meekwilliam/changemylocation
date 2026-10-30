// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "imsomeeked",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "imsomeeked", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
