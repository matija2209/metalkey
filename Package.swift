// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "metalkey",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "metalkey",
            path: "Sources/metalkey",
            // The kernels are compiled at runtime with device.makeLibrary(source:), so the
            // Metal toolchain (xcrun metal) is not needed: the source is embedded as bytes.
            resources: [.embedInCode("Shaders.metal")],
            linkerSettings: [
                .linkedFramework("Metal"), .linkedFramework("AVFoundation"), .linkedFramework("CoreVideo"),
                .linkedFramework("CoreMedia"), .linkedFramework("VideoToolbox"), .linkedFramework("ImageIO"),
                .linkedFramework("CoreGraphics"), .linkedFramework("CoreImage"),
            ]
        ),
    ]
)
