// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PingBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PingBar",
            path: "Sources/PingBar",
            linkerSettings: [
                .linkedFramework("ServiceManagement"),
                .linkedFramework("CoreWLAN")
            ]
        ),
        .testTarget(
            name: "PingBarTests",
            dependencies: ["PingBar"]
        )
    ],
    swiftLanguageModes: [.v6]
)
