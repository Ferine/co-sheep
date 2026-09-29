// swift-tools-version: 6.4
import PackageDescription

let concurrency: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "co-sheep",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "CoSheep", targets: ["CoSheep"]),
    ],
    targets: [
        .executableTarget(
            name: "CoSheep",
            dependencies: ["CoSheepKit"],
            swiftSettings: concurrency
        ),
        .target(
            name: "CoSheepKit",
            resources: [.copy("Resources")],
            swiftSettings: concurrency
        ),
        .testTarget(
            name: "CoSheepKitTests",
            dependencies: ["CoSheepKit"],
            swiftSettings: concurrency
        ),
    ]
)
