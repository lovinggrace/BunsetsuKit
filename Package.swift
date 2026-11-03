// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BunsetsuKit",
    platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16), .watchOS(.v9), .visionOS(.v1)],
    products: [
        .library(name: "BunsetsuKit", targets: ["BunsetsuKit"]),
        .executable(name: "bunsetsu", targets: ["bunsetsu"]),
    ],
    targets: [
        .target(
            name: "BunsetsuKit",
            resources: [.copy("Resources")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "bunsetsu", dependencies: ["BunsetsuKit"]),
        .testTarget(name: "BunsetsuKitTests", dependencies: ["BunsetsuKit"], resources: [.copy("Resources")]),
    ],
    swiftLanguageModes: [.v5]
)
