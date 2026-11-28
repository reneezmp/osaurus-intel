// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "osaurus-xlsx",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "osaurus-xlsx", type: .dynamic, targets: ["osaurus_xlsx"])
    ],
    dependencies: [
        .package(path: "../swift-sdk")
    ],
    targets: [
        .target(
            name: "osaurus_xlsx",
            dependencies: [
                .product(name: "OsaurusPluginABI", package: "swift-sdk"),
                .product(name: "OsaurusPluginKit", package: "swift-sdk"),
            ],
            path: "Sources/osaurus_xlsx"
        ),
        .testTarget(
            name: "osaurus_xlsx_tests",
            dependencies: [
                "osaurus_xlsx",
                .product(name: "OsaurusPluginTestSupport", package: "swift-sdk"),
            ],
            path: "Tests/osaurus_xlsx_tests"
        )
    ]
)
