// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PieFlow",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PieFlow",
            path: "Sources/PieFlow",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
