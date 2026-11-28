// swift-tools-version: 5.9
import PackageDescription

// All three products are EXPLICITLY static. Plugin release builds must
// produce exactly one dylib (the plugin itself) — the host enforces this.
// A `.dynamic` (or unspecified) library product here would emit a second
// dylib next to the plugin and break loading.
let package = Package(
    name: "osaurus-plugin-sdk",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OsaurusPluginABI", type: .static, targets: ["OsaurusPluginABI"]),
        .library(name: "OsaurusPluginKit", type: .static, targets: ["OsaurusPluginKit"]),
        .library(
            name: "OsaurusPluginTestSupport", type: .static,
            targets: ["OsaurusPluginTestSupport"]),
    ],
    targets: [
        .target(
            name: "OsaurusPluginABI",
            path: "Sources/OsaurusPluginABI"
        ),
        .target(
            name: "OsaurusPluginKit",
            dependencies: ["OsaurusPluginABI"],
            path: "Sources/OsaurusPluginKit"
        ),
        .target(
            name: "OsaurusPluginTestSupport",
            dependencies: ["OsaurusPluginABI", "OsaurusPluginKit"],
            path: "Sources/OsaurusPluginTestSupport"
        ),
        .testTarget(
            name: "OsaurusPluginABITests",
            dependencies: ["OsaurusPluginABI"],
            path: "Tests/OsaurusPluginABITests"
        ),
        .testTarget(
            name: "OsaurusPluginKitTests",
            dependencies: ["OsaurusPluginKit"],
            path: "Tests/OsaurusPluginKitTests"
        ),
        .testTarget(
            name: "OsaurusPluginTestSupportTests",
            dependencies: ["OsaurusPluginTestSupport"],
            path: "Tests/OsaurusPluginTestSupportTests"
        ),
    ]
)
