// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenLidSounds",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "OpenLidSounds", targets: ["OpenLidSounds"])
    ],
    targets: [
        .executableTarget(
            name: "OpenLidSounds",
            path: "Sources",
            exclude: ["Info.plist"]
        )
    ]
)
