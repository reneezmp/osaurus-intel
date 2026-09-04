// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OsaurusNetworking",
    platforms: [.macOS(.v13)],  // fork-specific: upstream pins .v15
    products: [
        .library(name: "OsaurusNetworking", targets: ["OsaurusNetworking"])
    ],
    targets: [
        .target(name: "OsaurusNetworking", path: "Sources")
    ]
)
