// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "GSDCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "GSDCore", targets: ["GSDCore"])],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        .target(name: "GSDCore", dependencies: ["SwiftSoup"]),
        .executableTarget(name: "gsd-dump", dependencies: ["GSDCore"]),
        .testTarget(
            name: "GSDCoreTests",
            dependencies: ["GSDCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
