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
    ],
    targets: [
        .target(
            name: "NotchAssistantCore",
            dependencies: [.product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")]
        ),
        // Patched copy of MrKai77/DynamicNotchKit 1.1.0; see Vendor/DynamicNotchKit/PATCHES.md.
        .target(name: "DynamicNotchKit", path: "Vendor/DynamicNotchKit", exclude: ["LICENSE", "PATCHES.md"]),
        .executableTarget(name: "NotchAssistant", dependencies: ["NotchAssistantCore", "DynamicNotchKit"]),
        .executableTarget(name: "PlanCLI", dependencies: ["NotchAssistantCore"]),
        .testTarget(name: "NotchAssistantCoreTests", dependencies: ["NotchAssistantCore"]),
    ]
)
