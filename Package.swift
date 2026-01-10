// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenStay",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(
            name: "ScreenStay",
            targets: ["ScreenStay"]
        )
    ],
    targets: [
        .executableTarget(
            name: "ScreenStay",
            path: "ScreenStay",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
