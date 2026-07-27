// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cairn",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "cairn", targets: ["Cairn"])
    ],
    targets: [
        .executableTarget(
            name: "Cairn",
            path: "Sources/Cairn",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "CairnTests",
            dependencies: ["Cairn"],
            path: "Tests/CairnTests"
        )
    ]
)
