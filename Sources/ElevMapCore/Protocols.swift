import Foundation

public enum DEMDataset: String, Sendable, Codable {
    /// Copernicus GLO-30 global 30m
    case glo30
    /// Geoscience Australia DEM-S 1 second Australia only.
    case demS30
    /// NSW 5m elevation NSW only
    case nsw5m

    public var displayName: String {
        switch self {
        case .glo30: "Copernicus GLO-30"
        case .demS30: "DEM-S-30"
        case .nsw5m: "NSW 5m Elevation"
        }
    }

    public var resolutionMeters: Double {
        switch self {
        case .glo30, .demS30: 30
        case .nsw5m: 5
        }
    }
}

public protocol ImagerySource: Sendable {
    func texture(for bounds: GeoBounds, maxDimension: Int) async throws -> TextureData
}

public protocol ElevationSource: Sendable {
    func heightField(for bounds: GeoBounds) async throws -> HeightField
}

public protocol HTTPRangeReader: Sendable {
    func read(_ url: URL, range: Range<Int>?) async throws -> Data
}

public enum ElevMapError: Error, CustomStringConvertible {
    case invalidBounds(GeoBounds)
    case areaTooLarge(requestedSquareKilometers: Double, limit: Double)
    case datasetDoesNotCoverBounds(DEMDataset, GeoBounds)
    case malformedResponse(String)
    case httpStatus(Int, URL)
    case decompressionFailed(String)

    public var description: String {
        switch self {
        case .invalidBounds(let b):
            "Invalid bounds: \(b)"
        case .areaTooLarge(let requested, let limit):
            "Requested area is \(Int(requested)) km², limit is \(Int(limit)) km²"
        case .datasetDoesNotCoverBounds(let d, let b):
            "\(d.displayName) does not cover \(b)"
        case .malformedResponse(let detail):
            "Malformed response: \(detail)"
        case .httpStatus(let code, let url):
            "HTTP \(code) for \(url.absoluteString)"
        case .decompressionFailed(let detail):
            "Decompression failed: \(detail)"
        }
    }
}
