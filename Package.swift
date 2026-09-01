// swift-tools-version: 6.3
import PackageDescription

// ElevMapKit: platform-agnostic terrain pipeline.
//
// Nothing in this package depends on a server framework, MapKit, or RealityKit.
// It builds unchanged for visionOS and for Linux; the web demo lives in its own
// package under Demo/ so that its dependencies never enter this graph.
let package = Package(
    name: "ElevMapKit",
    platforms: [
        .visionOS(.v2), .iOS(.v17), .macOS(.v14),
    ],
    products: [
        .library(name: "ElevMapKit", targets: ["ElevMapCore", "ElevMapGeo"]),
    ],
    targets: [
        .systemLibrary(name: "CZLib", path: "Sources/CZLib"),

        // Domain types and mesh generation. No I/O.
        .target(name: "ElevMapCore"),

        // Cloud-Optimized GeoTIFF reading: IFD parsing, tile decode.
        .target(name: "ElevMapGeo", dependencies: ["ElevMapCore", "CZLib"]),
    ],
    swiftLanguageModes: [.v6]
)
