// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "changemylocation",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Updates the app in place (signed with the project's EdDSA key; see .github/workflows/release.yml).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "changemylocation",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
