// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DoubleMouse",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DoubleMouse", targets: ["DoubleMouse"])
    ],
    targets: [
        .executableTarget(
            name: "DoubleMouse",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
