// swift-tools-version: 6.3
import PackageDescription

// The web demo
let package = Package(
    name: "ElevMapDemo",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "ElevMapKit", path: ".."),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    ],
    targets: [
        .executableTarget(
            name: "ElevMapDemoServer",
            dependencies: [
                .product(name: "ElevMapKit", package: "ElevMapKit"),
                .product(name: "ElevMapExport", package: "ElevMapKit"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
