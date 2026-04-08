// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "HDRUpscaler",
    platforms: [
        .macOS(.v14)  // ScreenCaptureKit SCContentSharingPicker requires macOS 14+
    ],
    targets: [
        // Core library — pure logic, testable without GPU or app lifecycle
        .target(
            name: "HDRUpscalerCore",
            path: "Sources/HDRUpscalerCore"
        ),

        // Main executable — depends on Core for types and utilities
        .executableTarget(
            name: "HDRUpscaler",
            dependencies: ["HDRUpscalerCore"],
            path: "Sources/HDRUpscaler",
            resources: [
                .process("Resources"),
                .copy("sdr_to_hdr.metal")
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("MetalFX"),
                .linkedFramework("AppKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("MetalPerformanceShaders"),
            ]
        ),

        // Unit tests — tests Core library (pure logic, no GPU required)
        .testTarget(
            name: "HDRUpscalerTests",
            dependencies: ["HDRUpscalerCore"],
            path: "Tests/HDRUpscalerTests"
        ),
    ]
)
