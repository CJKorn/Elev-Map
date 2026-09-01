import ElevMapCore
import ElevMapGeo
import Foundation

/// An `ElevationSource` backed by one very large Cloud-Optimized GeoTIFF.
///
/// DEM-S is published as a single 38 GB continent-wide BigTIFF rather than as
/// per-degree tiles, so there is nothing to stitch — just a window read. The
/// opened header is kept because parsing it costs about a megabyte of ranged
/// reads, most of it the tile-offset table.
public actor SingleRasterDEMSource: ElevationSource {
    private let url: URL
    private let reader: HTTPRangeReader
    private let dataset: DEMDataset
    private let coverage: GeoBounds?
    private let headerSize: Int
    private var opened: CloudOptimizedGeoTIFF?

    public init(
        url: URL,
        reader: HTTPRangeReader,
        dataset: DEMDataset,
        coverage: GeoBounds? = nil,
        headerSize: Int = 64 * 1024
    ) {
        self.url = url
        self.reader = reader
        self.dataset = dataset
        self.coverage = coverage
        self.headerSize = headerSize
    }

    public func heightField(for bounds: GeoBounds) async throws -> HeightField {
        if let coverage, !intersects(bounds, coverage) {
            throw ElevMapError.datasetDoesNotCoverBounds(dataset, bounds)
        }
        await ProgressReporter.report(
            0.05, opened == nil ? "Opening the continental raster" : "Reading elevation samples")
        let raster = try await open()
        await ProgressReporter.report(0.5, "Reading elevation samples")
        let field = try await ProgressReporter.spanning(0.5...0.95) {
            try await raster.heightField(for: bounds)
        }
        await ProgressReporter.report(1, "Elevation ready")
        return field
    }

    private func open() async throws -> CloudOptimizedGeoTIFF {
        if let opened { return opened }
        let raster = try await CloudOptimizedGeoTIFF(
            url: url, reader: reader, headerSize: headerSize)
        opened = raster
        return raster
    }

    private func intersects(_ a: GeoBounds, _ b: GeoBounds) -> Bool {
        a.west < b.east && a.east > b.west && a.south < b.north && a.north > b.south
    }
}

extension SingleRasterDEMSource {
    /// Geoscience Australia's SRTM-derived 1 second DEM-S — smoothed bare
    /// earth — as published on Digital Earth Australia's public bucket.
    ///
    /// One 147600 x 122400 BigTIFF, 38 GB, float32, 512 px tiles, no key. A
    /// typical box reads a megabyte of it.
    public static func demS30(
        reader: HTTPRangeReader,
        url: URL = URL(
            string:
                "https://dea-public-data.s3.ap-southeast-2.amazonaws.com/projects/elevation/ga_srtm_dem1sv1_0/dems1sv1_0.tif"
        )!
    ) -> SingleRasterDEMSource {
        SingleRasterDEMSource(
            url: url, reader: reader, dataset: .demS30,
            coverage: GeoBounds(south: -44.5, west: 112.0, north: -9.0, east: 154.5))
    }
}
