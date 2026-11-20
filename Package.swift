// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KeyGlance",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "KeyGlance",
            path: "Sources/KeyGlance",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
