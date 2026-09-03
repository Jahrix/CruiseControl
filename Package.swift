// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CruiseControlCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CruiseControlCore", targets: ["CruiseControlCore"])
    ],
    targets: [
        .target(
            name: "CruiseControlCore",
            path: "CruiseControl/Core"
        ),
        .testTarget(
            name: "CruiseControlCoreTests",
            dependencies: ["CruiseControlCore"],
            path: "Tests/CruiseControlCoreTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
