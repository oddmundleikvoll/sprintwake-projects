// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fjord",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FjordCore", targets: ["FjordCore"]),
        .executable(name: "Fjord", targets: ["Fjord"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(name: "FjordCore", resources: [.process("Resources")]),
        .executableTarget(name: "Fjord", dependencies: ["FjordCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "FjordCoreTests", dependencies: ["FjordCore"])
    ]
)
