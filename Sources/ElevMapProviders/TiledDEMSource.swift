import ElevMapCore
import ElevMapGeo
import Foundation

/// A source of elevation data that is tiled
public struct TiledDEMSource: ElevationSource {
    public typealias TileURLBuilder = @Sendable (_ latitude: Int, _ longitude: Int) -> URL?

    private let reader: HTTPRangeReader
    private let dataset: DEMDataset
    private let coverage: GeoBounds?
    private let tileURL: TileURLBuilder

    public init(
        dataset: DEMDataset,
        reader: HTTPRangeReader,
        coverage: GeoBounds? = nil,
        tileURL: @escaping TileURLBuilder
    ) {
        self.dataset = dataset
        self.reader = reader
        self.coverage = coverage
        self.tileURL = tileURL
    }
    
    public func heightField(for bounds: GeoBounds) async throws -> HeightField {
        if let coverage, !intersects(bounds, coverage) {
            throw ElevMapError.datasetDoesNotCoverBounds(dataset, bounds)
        }

        let urls = tileGrid(covering: bounds).compactMap(tileURL)
        let fields = urls.count == 1
            ? try await [readTile(urls[0], bounds: bounds)].compactMap { $0 }
            : try await readTiles(urls, bounds: bounds)

        guard let first = fields.first else {
            throw ElevMapError.malformedResponse("no \(dataset.displayName) tiles could be read for \(bounds)")
        }
        await ProgressReporter.report(0.95, "Stitching elevation tiles")
        let field = fields.count == 1 ? first : stitched(fields, bounds: bounds)
        await ProgressReporter.report(1, "Elevation ready")
        return field
    }

    /// One tile, reported in the two steps a COG actually takes: the header
    /// and offset table, then the sample windows.
    private func readTile(_ url: URL, bounds: GeoBounds) async throws -> HeightField? {
        await ProgressReporter.report(0.05, "Opening the elevation tile")
        guard let cog = try? await CloudOptimizedGeoTIFF(url: url, reader: reader) else {
            return nil
        }
        await ProgressReporter.report(0.35, "Reading elevation samples")
        // One tile, so the COG's block reads own the rest of the channel.
        return try? await ProgressReporter.spanning(0.35...0.95) {
            try await cog.heightField(for: bounds)
        }
    }

    /// Tiles read concurrently, so progress is whole tiles finished. Nothing
    /// finer would be honest: the reads interleave.
    private func readTiles(_ urls: [URL], bounds: GeoBounds) async throws -> [HeightField] {
        await ProgressReporter.report(0.02, "Reading \(urls.count) elevation tiles")
        return try await withThrowingTaskGroup(of: HeightField?.self) { group in
            for url in urls {
                group.addTask {
                    let cog = try? await CloudOptimizedGeoTIFF(url: url, reader: reader)
                    return try? await cog?.heightField(for: bounds)
                }
            }
            var out: [HeightField] = []
            var finished = 0
            for try await field in group {
                finished += 1
                await ProgressReporter.report(
                    0.02 + 0.9 * Double(finished) / Double(urls.count),
                    "Read \(finished) of \(urls.count) elevation tiles")
                if let field { out.append(field) }
            }
            return out
        }
    }

    /// Build a grid of tiles
    private func stitched(_ fields: [HeightField], bounds: GeoBounds) -> HeightField {
        let reference = fields[0]
        let spacingLon = reference.bounds.longitudeSpan / Double(max(reference.width - 1, 1))
        let spacingLat = reference.bounds.latitudeSpan / Double(max(reference.height - 1, 1))
        guard spacingLon > 0, spacingLat > 0 else { return reference }

        let westSteps = ((bounds.west - reference.bounds.west) / spacingLon).rounded(.down)
        let northSteps = ((reference.bounds.north - bounds.north) / spacingLat).rounded(.down)
        let west = reference.bounds.west + westSteps * spacingLon
        let north = reference.bounds.north - northSteps * spacingLat

        let width = max(Int((bounds.longitudeSpan / spacingLon).rounded(.up)) + 1, 2)
        let height = max(Int((bounds.latitudeSpan / spacingLat).rounded(.up)) + 1, 2)
        let east = west + Double(width - 1) * spacingLon
        let south = north - Double(height - 1) * spacingLat
        let grid = GeoBounds(south: south, west: west, north: north, east: east)

        var output = HeightField(
            width: width, height: height, bounds: grid, repeating: HeightField.noData)

        for y in 0..<height {
            let lat = grid.north - (Double(y) / Double(height - 1)) * grid.latitudeSpan
            for x in 0..<width {
                let lon = grid.west + (Double(x) / Double(width - 1)) * grid.longitudeSpan
                for field in fields where contains(field.bounds, lat: lat, lon: lon) {
                    let u = (lon - field.bounds.west) / field.bounds.longitudeSpan
                    let v = (field.bounds.north - lat) / field.bounds.latitudeSpan
                    let value = field.nearestSample(u: u, v: v)
                    if value != HeightField.noData {
                        output[x, y] = value
                        break
                    }
                }
            }
        }
        return output
    }

    private func tileGrid(covering bounds: GeoBounds) -> [(Int, Int)] {
        let lats = Int(bounds.south.rounded(.down))...Int((bounds.north - 1e-9).rounded(.down))
        let lons = Int(bounds.west.rounded(.down))...Int((bounds.east - 1e-9).rounded(.down))
        return lats.flatMap { lat in lons.map { (lat, $0) } }
    }

    private func contains(_ b: GeoBounds, lat: Double, lon: Double) -> Bool {
        lat >= b.south && lat <= b.north && lon >= b.west && lon <= b.east
    }

    private func intersects(_ a: GeoBounds, _ b: GeoBounds) -> Bool {
        a.west < b.east && a.east > b.west && a.south < b.north && a.north > b.south
    }
}
extension TiledDEMSource {
    /// Copernicus GLO-30 as published on AWS Open Data.
    ///
    /// Tile names carry the south-west corner of each 1 degree cell:
    /// `Copernicus_DSM_COG_10_N47_00_E008_00_DEM/…_DEM.tif`.
    public static func copernicusGLO30(
        reader: HTTPRangeReader,
        baseURL: URL = URL(string: "https://copernicus-dem-30m.s3.amazonaws.com")!
    ) -> TiledDEMSource {
        TiledDEMSource(dataset: .glo30, reader: reader) { lat, lon in
            let name = String(
                format: "Copernicus_DSM_COG_10_%@%02d_00_%@%03d_00_DEM",
                lat >= 0 ? "N" : "S", abs(lat), lon >= 0 ? "E" : "W", abs(lon))
            return baseURL.appendingPathComponent(name).appendingPathComponent("\(name).tif")
        }
    }
}
