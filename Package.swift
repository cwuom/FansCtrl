// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FansCtrl",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "fanctld", targets: ["fanctld"]),
        .executable(name: "fanctl", targets: ["fanctl"]),
        .executable(name: "FansCtrlApp", targets: ["FansCtrlApp"]),
    ],
    targets: [
        .target(name: "CSMC", linkerSettings: [.linkedFramework("IOKit")]),
        .target(
            name: "FanCore",
            dependencies: ["CSMC"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("SystemConfiguration")]
        ),
        .executableTarget(name: "fanctld", dependencies: ["FanCore"]),
        .executableTarget(name: "fanctl", dependencies: ["FanCore"]),
        .executableTarget(name: "FansCtrlApp", dependencies: ["FanCore"]),
        .testTarget(name: "FanCoreTests", dependencies: ["FanCore"]),
    ]
)
