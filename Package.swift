// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Search",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .executableTarget(
            name: "Search",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Search",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "BroadwayCLI",
            path: "Sources/BroadwayCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "broadway",
            dependencies: ["BroadwayCLI"],
            path: "Sources/broadway",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SearchTests",
            dependencies: ["Search"],
            path: "Tests/SearchTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BroadwayCLITests",
            dependencies: ["BroadwayCLI"],
            path: "Tests/BroadwayCLITests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
