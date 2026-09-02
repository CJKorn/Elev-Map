import ElevMapCore
import ElevMapExport
import ElevMapProviders
import Foundation
import Hummingbird
import Logging

// Everything below this line is throwaway. The Vision Pro app replaces it with
// a MapKit selection and a RealityKit entity, and calls the identical
// `TerrainService.buildTerrain`.

let logger = Logger(label: "elev-map-demo")

// See AsyncHTTPClientRangeReader for why the demo does not use the library's
// URLSessionRangeReader, which is what the visionOS app would use.
let reader = AsyncHTTPClientRangeReader()
let cacheDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("elev-map-cache", isDirectory: true)
let cachingReader = CachingRangeReader(
    upstream: reader, cache: try FileTileCache(directory: cacheDirectory))

let elevation: [DEMDataset: any ElevationSource] = [
    .glo30: TiledDEMSource.copernicusGLO30(reader: cachingReader),
    .demS30: SingleRasterDEMSource.demS30(reader: cachingReader),
    // Worth caching despite being generated per request: a cold render takes
    // tens of seconds, and revisiting the same view repeats the URL exactly.
    .nsw5m: ArcGISImageServerSource.nsw5mElevation(reader: cachingReader),
]
let imagery = WebMapImagerySource.esriWorldImagery(reader: reader)
let terrain = TerrainService(elevation: elevation, imagery: imagery)
let jobs = TerrainJobs(service: terrain)

let router = Router()
router.add(middleware: LogRequestsMiddleware(.info))
router.add(middleware: FileMiddleware("Public", searchForIndexHtml: true, logger: logger))

struct DatasetInfo: ResponseEncodable {
    var id: String
    var name: String
    var resolutionMeters: Double
    var coverage: String
}

struct Config: ResponseEncodable {
    var bounds: GeoBounds
    var maxSpanDegrees: Double
    var maxAreaSquareKilometers: Double
    var datasets: [DatasetInfo]
}

/// What the picker needs to constrain a selection before anything is fetched.
router.get("/api/config") { _, _ in
    Config(
        bounds: GeoBounds(south: -60, west: -180, north: 72, east: 180),
        maxSpanDegrees: 0.6,
        maxAreaSquareKilometers: 40_000,
        datasets: [
            DatasetInfo(
                id: DEMDataset.glo30.rawValue, name: DEMDataset.glo30.displayName,
                resolutionMeters: DEMDataset.glo30.resolutionMeters, coverage: "global"),
            DatasetInfo(
                id: DEMDataset.nsw5m.rawValue, name: DEMDataset.nsw5m.displayName,
                resolutionMeters: DEMDataset.nsw5m.resolutionMeters,
                coverage: "New South Wales"),
            DatasetInfo(
                id: DEMDataset.demS30.rawValue, name: DEMDataset.demS30.displayName,
                resolutionMeters: DEMDataset.demS30.resolutionMeters,
                coverage: "Australia"),
        ])
}

struct StartedJob: ResponseEncodable {
    var id: String
}

/// Starts a build and returns immediately; the page polls for progress.
router.post("/api/terrain") { request, context -> StartedJob in
    let terrainRequest = try await request.decode(as: TerrainRequest.self, context: context)
    guard terrainRequest.bounds.isValid else {
        throw HTTPError(.badRequest, message: "invalid bounds")
    }
    return StartedJob(id: await jobs.start(terrainRequest))
}

router.get("/api/terrain/:id") { _, context -> TerrainJobs.Status in
    let id = try context.parameters.require("id")
    guard let status = await jobs.status(id) else {
        throw HTTPError(.notFound, message: "no such job")
    }
    return status
}

router.delete("/api/terrain/:id") { _, context -> HTTPResponse.Status in
    await jobs.cancel(try context.parameters.require("id"))
    return .noContent
}

/// The finished model, as a self-contained glTF binary.
router.get("/api/terrain/:id/model") { _, context -> Response in
    let id = try context.parameters.require("id")
    guard let glb = await jobs.model(id) else {
        throw HTTPError(.notFound, message: "model not ready")
    }
    return Response(
        status: .ok,
        headers: [.contentType: "model/gltf-binary"],
        body: .init(byteBuffer: ByteBuffer(bytes: glb)))
}

/// Basemap proxy. OpenStreetMap's tile policy asks for an identifying
/// User-Agent, which a browser will not send on our behalf, and proxying keeps
/// the tiles same-origin and cached on disk with everything else.
router.get("/api/tiles/osm/:z/:x/:y") { _, context -> Response in
    let z = try context.parameters.require("z", as: Int.self)
    let x = try context.parameters.require("x", as: Int.self)
    let name = try context.parameters.require("y")
    let y = Int(name.replacingOccurrences(of: ".png", with: "")) ?? 0
    guard (0...19).contains(z), x >= 0, y >= 0 else {
        throw HTTPError(.badRequest, message: "bad tile coordinates")
    }

    let url = URL(string: "https://tile.openstreetmap.org/\(z)/\(x)/\(y).png")!
    let tiles = AsyncHTTPClientRangeReader(
        headers: ["User-Agent": "Elev-Map demo (https://github.com/CJKorn/Elev-Map)"])
    do {
        let data = try await CachingRangeReader(
            upstream: tiles,
            cache: try FileTileCache(directory: cacheDirectory)
        ).read(url, range: nil)
        return Response(
            status: .ok,
            headers: [.contentType: "image/png", .cacheControl: "public, max-age=86400"],
            body: .init(byteBuffer: ByteBuffer(bytes: data)))
    } catch {
        throw HTTPError(.badGateway, message: "tile fetch failed")
    }
}

let app = Application(
    router: router,
    configuration: .init(address: .hostname("127.0.0.1", port: 8080)),
    logger: logger)
try await app.runService()
