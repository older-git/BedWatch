// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MCRProtocol",
    platforms: [.watchOS(.v10), .iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MCRProtocol", targets: ["MCRProtocol"]),
        .library(name: "MCRBluetooth", targets: ["MCRBluetooth"]),
        .executable(name: "bedctl", targets: ["bedctl"]),
    ],
    targets: [
        .target(name: "MCRProtocol"),
        .target(name: "MCRBluetooth", dependencies: ["MCRProtocol"]),
        .executableTarget(
            name: "bedctl",
            dependencies: ["MCRProtocol", "MCRBluetooth"],
            exclude: ["Info.plist"],
            // CoreBluetooth needs NSBluetoothAlwaysUsageDescription even for a CLI.
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                "-Xlinker", "Sources/bedctl/Info.plist",
            ])]
        ),
        .testTarget(name: "MCRProtocolTests", dependencies: ["MCRProtocol"]),
    ]
)
