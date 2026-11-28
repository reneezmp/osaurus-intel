// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "osaurus-pptx",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "osaurus-pptx", type: .dynamic, targets: ["osaurus_pptx"])
    ],
    dependencies: [
        .package(path: "../swift-sdk")
    ],
    targets: [
        .target(
            name: "osaurus_pptx",
            dependencies: [
                .product(name: "OsaurusPluginABI", package: "swift-sdk"),
                .product(name: "OsaurusPluginKit", package: "swift-sdk"),
            ],
            path: "Sources/osaurus_pptx"
        ),
        .testTarget(
            name: "osaurus_pptx_tests",
            dependencies: [
                "osaurus_pptx",
                .product(name: "OsaurusPluginTestSupport", package: "swift-sdk"),
            ],
            path: "Tests/osaurus_pptx_tests"
        )
    ]
)
