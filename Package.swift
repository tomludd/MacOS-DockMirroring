// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacDockEverywhere",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacDockEverywhere",
            path: "Sources/MacDockEverywhere",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
