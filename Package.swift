// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NotchAssistant",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "NotchAssistant", targets: ["NotchAssistant"]),
        .executable(name: "plan-cli", targets: ["PlanCLI"]),
    ],
    dependencies: [
        // Runs the wake-word models (MIT).
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.19.2"),
        // Kokoro-82M on the Neural Engine, for the natural voice (Apache-2.0).
        // No traits: leaves out a prebuilt text-normalisation binary that
        // only non-English voices use.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.17.4"), traits: []),
    ],
    targets: [
        .target(
            name: "NotchAssistantCore",
            dependencies: [.product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")]
        ),
        // Patched copy of MrKai77/DynamicNotchKit 1.1.0; see Vendor/DynamicNotchKit/PATCHES.md.
        .target(name: "DynamicNotchKit", path: "Vendor/DynamicNotchKit", exclude: ["LICENSE", "PATCHES.md"]),
        .executableTarget(
            name: "NotchAssistant",
            dependencies: ["NotchAssistantCore", "DynamicNotchKit", .product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .executableTarget(name: "PlanCLI", dependencies: ["NotchAssistantCore"]),
        .testTarget(name: "NotchAssistantCoreTests", dependencies: ["NotchAssistantCore"]),
    ]
)
