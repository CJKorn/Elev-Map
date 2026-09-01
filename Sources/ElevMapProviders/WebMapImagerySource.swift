import ElevMapCore
import Foundation

/// Satellite imagery from any service that renders a bounding box to one image.
///
/// Not an XYZ tile stitcher: stitching needs an image decoder, and there isn't
/// one on both Linux and visionOS without a dependency. One bbox request means
/// the bytes pass through to the glTF or to `TextureResource` undecoded.
public struct WebMapImagerySource: ImagerySource {
    public typealias URLBuilder = @Sendable (
        _ bounds: GeoBounds, _ width: Int, _ height: Int
    ) -> URL?

    private let reader: HTTPRangeReader
    private let format: TextureData.Format
    private let maxSupportedDimension: Int
    private let nativeZoom: Int?
    private let retry: RetryPolicy
    private let buildURL: URLBuilder

    /// - Parameters:
    ///   - nativeZoom: the deepest Web Mercator zoom the service holds real
    ///     pixels for. A request is never sized beyond what that zoom contains,
    ///     so a small box comes back sharp instead of upscaled.
    ///   - retry: wraps the fetch *and* the payload check, because a service
    ///     that fails to render usually says so in the body, not the status.
    public init(
        reader: HTTPRangeReader,
        format: TextureData.Format = .jpeg,
        maxSupportedDimension: Int = 4096,
        nativeZoom: Int? = nil,
        retry: RetryPolicy = RetryPolicy(),
        buildURL: @escaping URLBuilder
    ) {
        self.reader = reader
        self.format = format
        self.maxSupportedDimension = maxSupportedDimension
        self.nativeZoom = nativeZoom
        self.retry = retry
        self.buildURL = buildURL
    }

    public func texture(for bounds: GeoBounds, maxDimension: Int) async throws -> TextureData {
        // Services clamp silently past their own limit, which would leave the
        // dimensions on TextureData disagreeing with the bytes.
        var longest = min(maxDimension, maxSupportedDimension)
        if let nativeZoom {
            let worldPixels = 256.0 * pow(2, Double(nativeZoom))
            let across = worldPixels * max(bounds.longitudeSpan, bounds.latitudeSpan) / 360
            longest = min(longest, max(64, Int(across.rounded())))
        }

        let aspect = bounds.longitudeSpan / max(bounds.latitudeSpan, 1e-9)
        // Rounded, not truncated: a square box works out a hair under 1.0 in
        // floating point and would otherwise come back a pixel short.
        let width = aspect >= 1 ? longest : max(1, Int((Double(longest) * aspect).rounded()))
        let height = aspect >= 1 ? max(1, Int((Double(longest) / aspect).rounded())) : longest

        guard let url = buildURL(bounds, width, height) else {
            throw ElevMapError.malformedResponse("could not build imagery URL")
        }

        await ProgressReporter.report(0.03, "Requesting a \(width) x \(height) satellite image")
        let data = try await retry.run {
            let data = try await ProgressReporter.spanning(0.03...1, oneRequest: true) {
                try await reader.read(url, range: nil)
            }
            try Self.validate(data, format: format, url: url)
            return data
        }
        await ProgressReporter.report(1, "Satellite imagery ready")
        return TextureData(format: format, width: width, height: height, bytes: data)
    }

    /// Rejects anything that is not the image we asked for, so a JSON error
    /// body never reaches the texture loader.
    private static func validate(_ data: Data, format: TextureData.Format, url: URL) throws {
        guard !data.isEmpty else {
            throw ElevMapError.malformedResponse("empty imagery response")
        }
        if data.first == UInt8(ascii: "{") {
            throw ElevMapError.malformedResponse(
                "imagery service returned an error: "
                    + String(decoding: data.prefix(300), as: UTF8.self))
        }

        let bytes = [UInt8](data.prefix(8))
        switch format {
        case .jpeg:
            guard bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF else {
                throw ElevMapError.malformedResponse("expected JPEG from \(url.host ?? "")")
            }
        case .png:
            let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            guard bytes.count >= 8, Array(bytes[0..<8]) == signature else {
                throw ElevMapError.malformedResponse("expected PNG from \(url.host ?? "")")
            }
        }
    }
}

extension WebMapImagerySource {
    /// Esri World Imagery, which renders up to 4096 px on its longest edge.
    /// Fine for a demo; check licensing before shipping it.
    public static func esriWorldImagery(
        reader: HTTPRangeReader, retry: RetryPolicy = RetryPolicy()
    ) -> WebMapImagerySource {
        let base = "https://services.arcgisonline.com/ArcGIS/rest/services"
            + "/World_Imagery/MapServer/export"
        return WebMapImagerySource(
            reader: reader, format: .jpeg, maxSupportedDimension: 4096, nativeZoom: 19,
            retry: retry
        ) { bounds, width, height in
            var components = URLComponents(string: base)
            components?.queryItems = [
                URLQueryItem(
                    name: "bbox",
                    value: "\(bounds.west),\(bounds.south),\(bounds.east),\(bounds.north)"),
                URLQueryItem(name: "bboxSR", value: "4326"),
                URLQueryItem(name: "imageSR", value: "4326"),
                URLQueryItem(name: "size", value: "\(width),\(height)"),
                URLQueryItem(name: "format", value: "jpg"),
                URLQueryItem(name: "f", value: "image"),
            ]
            return components?.url
        }
    }
}
