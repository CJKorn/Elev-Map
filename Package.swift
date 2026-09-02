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
        .library(name: "ElevMapKit", targets: ["ElevMapCore", "ElevMapGeo", "ElevMapProviders"]),
        .library(name: "ElevMapExport", targets: ["ElevMapExport"]),
        .library(name: "ElevMapRealityKit", targets: ["ElevMapRealityKit"]),
    ],
    targets: [
        .systemLibrary(name: "CZLib", path: "Sources/CZLib"),

        // Domain types and mesh generation. No I/O.
        .target(name: "ElevMapCore"),

        // Cloud-Optimized GeoTIFF reading: IFD parsing, tile decode.
        .target(name: "ElevMapGeo", dependencies: ["ElevMapCore", "CZLib"]),

        // Concrete DEM/imagery sources plus the URLSession range reader.
        .target(name: "ElevMapProviders", dependencies: ["ElevMapCore", "ElevMapGeo"]),

        // TerrainModel -> glTF binary. Used by the demo; harmless on device.
        .target(name: "ElevMapExport", dependencies: ["ElevMapCore"]),

        // MapKit and RealityKit glue for the visionOS app. Compiles to an
        // empty module anywhere those frameworks do not exist, so the package
        // still builds on Linux for the demo.
        .target(name: "ElevMapRealityKit", dependencies: ["ElevMapCore"]),
    ],
    swiftLanguageModes: [.v6]
)
