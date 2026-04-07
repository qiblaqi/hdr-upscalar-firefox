// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "HDRUpscaler",
    platforms: [
        .macOS(.v14)  // ScreenCaptureKit SCContentSharingPicker requires macOS 14+
    ],
    targets: [
        .executableTarget(
            name: "HDRUpscaler",
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
        )
    ]
)
