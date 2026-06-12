// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IntelStubs",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MLX", targets: ["MLX"]),
        .library(name: "MLXRandom", targets: ["MLXRandom"]),
        .library(name: "MLXLLM", targets: ["MLXLLM"]),
        .library(name: "MLXVLM", targets: ["MLXVLM"]),
        .library(name: "MLXLMCommon", targets: ["MLXLMCommon"]),
        .library(name: "VMLXTokenizers", targets: ["VMLXTokenizers"]),
        .library(name: "VMLXJinja", targets: ["VMLXJinja"]),
        .library(name: "FluidAudio", targets: ["FluidAudio"]),
        .library(name: "Containerization", targets: ["Containerization"]),
        .library(name: "ContainerizationExtras", targets: ["ContainerizationExtras"]),
        .library(name: "VecturaKit", targets: ["VecturaKit"]),
    ],
    targets: [
        .target(name: "MLX"),
        .target(name: "MLXRandom"),
        .target(name: "MLXLLM", dependencies: ["MLX"]),
        .target(name: "MLXVLM", dependencies: ["MLX"]),
        .target(name: "MLXLMCommon", dependencies: ["MLX", "MLXLLM", "MLXVLM", "VMLXTokenizers"]),
        .target(name: "VMLXTokenizers"),
        .target(name: "VMLXJinja"),
        .target(name: "FluidAudio", dependencies: ["Containerization"]),
        .target(name: "Containerization", dependencies: ["MLXLMCommon"]),
        .target(name: "ContainerizationExtras"),
        .target(name: "VecturaKit"),
    ]
)
