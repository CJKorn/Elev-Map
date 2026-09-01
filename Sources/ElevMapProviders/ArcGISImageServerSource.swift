import ElevMapCore
import ElevMapGeo
import Foundation

/// An `ElevationSource` backed by an ArcGIS ImageServer.
///
/// A different shape from the COG sources: the server clips and resamples, and
/// returns one GeoTIFF, so there is no tiling scheme and no window to choose.
public struct ArcGISImageServerSource: ElevationSource {
    private let reader: HTTPRangeReader
    private let serviceURL: URL
    private let dataset: DEMDataset
    private let coverage: GeoBounds
    private let nativeResolutionMeters: Double
    private let maxImageWidth: Int
    private let maxImageHeight: Int

    public init(
        serviceURL: URL,
        reader: HTTPRangeReader,
        dataset: DEMDataset,
        coverage: GeoBounds,
        nativeResolutionMeters: Double,
        maxImageWidth: Int = 4100,
        maxImageHeight: Int = 4100
    ) {
        self.serviceURL = serviceURL
        self.reader = reader
        self.dataset = dataset
        self.coverage = coverage
        self.nativeResolutionMeters = nativeResolutionMeters
        self.maxImageWidth = maxImageWidth
        self.maxImageHeight = maxImageHeight
    }

    public func heightField(for bounds: GeoBounds) async throws -> HeightField {
        guard intersects(bounds, coverage) else {
            throw ElevMapError.datasetDoesNotCoverBounds(dataset, bounds)
        }

        let size = pixelSize(for: bounds)
        guard let url = exportURL(bounds: bounds, width: size.width, height: size.height) else {
            throw ElevMapError.malformedResponse("could not build exportImage URL")
        }

        await ProgressReporter.report(
            0.03, "Rendering a \(size.width) x \(size.height) elevation raster")
        // One request, and the slow one: hand it most of the channel so a
        // reader that can see the response length has room to report bytes.
        let data = try await ProgressReporter.spanning(0.03...0.9, oneRequest: true) {
            try await reader.read(url, range: nil)
        }
        // ArcGIS reports failures as JSON with a 200 status.
        guard data.count > 4, data.first != UInt8(ascii: "{") else {
            throw ElevMapError.malformedResponse(String(decoding: data.prefix(400), as: UTF8.self))
        }

        await ProgressReporter.report(0.92, "Decoding the elevation raster")
        // The response arrived whole, so parse it in place rather than refetch.
        let raster = try await CloudOptimizedGeoTIFF(url: url, reader: DataRangeReader(data))
        let field = try await raster.heightField(for: bounds)
        await ProgressReporter.report(1, "Elevation ready")
        return field
    }

    /// ArcGIS renders square pixels in *degrees*, so a size derived from metres
    /// comes back coarser than native on the north-south axis. Size from the
    /// tighter of the two constraints instead: some redundancy east-west, no
    /// lost detail either way.
    private func pixelSize(for bounds: GeoBounds) -> (width: Int, height: Int) {
        let frame = LocalENU(origin: bounds.center)
        let degreesPerPixel = nativeResolutionMeters
            / max(frame.metersPerDegreeLatitude, frame.metersPerDegreeLongitude)
        var width = bounds.longitudeSpan / degreesPerPixel
        var height = bounds.latitudeSpan / degreesPerPixel

        // Clamp proportionally so the pixels stay square and the image keeps
        // covering the requested rectangle.
        let scale = min(
            1, min(Double(maxImageWidth) / max(width, 1), Double(maxImageHeight) / max(height, 1)))
        width *= scale
        height *= scale
        return (max(2, Int(width.rounded())), max(2, Int(height.rounded())))
    }

    private func exportURL(bounds: GeoBounds, width: Int, height: Int) -> URL? {
        var components = URLComponents(
            url: serviceURL.appendingPathComponent("exportImage"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(
                name: "bbox",
                value: "\(bounds.west),\(bounds.south),\(bounds.east),\(bounds.north)"),
            URLQueryItem(name: "bboxSR", value: "4326"),
            // Staying in 4326 keeps the raster on the pipeline's lat/lon grid
            // and avoids a slow server-side reprojection.
            URLQueryItem(name: "imageSR", value: "4326"),
            URLQueryItem(name: "size", value: "\(width),\(height)"),
            URLQueryItem(name: "format", value: "tiff"),
            URLQueryItem(name: "pixelType", value: "F32"),
            URLQueryItem(name: "interpolation", value: "RSP_BilinearInterpolation"),
            URLQueryItem(name: "f", value: "image"),
        ]
        return components?.url
    }

    private func intersects(_ a: GeoBounds, _ b: GeoBounds) -> Bool {
        a.west < b.east && a.east > b.west && a.south < b.north && a.north > b.south
    }
}

extension ArcGISImageServerSource {
    /// NSW 5 m Elevation from SIX Maps. Coverage and the size caps come from
    /// the service's own `?f=json` metadata.
    public static func nsw5mElevation(reader: HTTPRangeReader) -> ArcGISImageServerSource {
        ArcGISImageServerSource(
            serviceURL: URL(
                string: "https://maps.six.nsw.gov.au/arcgis/rest/services/public"
                    + "/NSW_5M_Elevation/ImageServer")!,
            reader: reader,
            dataset: .nsw5m,
            coverage: GeoBounds(south: -37.512, west: 141.0, north: -27.997, east: 154.005),
            nativeResolutionMeters: 5,
            maxImageWidth: 15_000,
            maxImageHeight: 4_100)
    }
}
