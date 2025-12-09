// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "swift-scip-indexer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "swift-scip-indexer",
            targets: ["SwiftSCIPIndexer"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            from: "1.5.0"
        ),
        .package(
            url: "https://github.com/swiftlang/indexstore-db",
            branch: "main"
        ),
    ],
    targets: [
        .executableTarget(
            name: "SwiftSCIPIndexer",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "IndexStoreDB", package: "indexstore-db"),
            ],
            path: "Sources/SwiftSCIPIndexer",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .testTarget(
            name: "SwiftSCIPIndexerTests",
            dependencies: ["SwiftSCIPIndexer"],
            path: "Tests/SwiftSCIPIndexerTests"
        ),
    ]
)

