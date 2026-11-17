// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DeepmacOS",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DeepmacOS", targets: ["DeepmacOS"])
    ],
    targets: [
        .executableTarget(
            name: "DeepmacOS",
            path: "Sources/DeepmacOS"
        )
    ]
)
