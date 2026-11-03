// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "hokusai-hummingbird",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HokusaiHummingbird", targets: ["HokusaiHummingbird"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/ivantokar/hokusai.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "HokusaiHummingbird",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Hokusai", package: "hokusai"),
                .product(name: "HokusaiNIO", package: "hokusai"),
            ]
        ),
        .testTarget(
            name: "HokusaiHummingbirdTests",
            dependencies: [
                "HokusaiHummingbird",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
