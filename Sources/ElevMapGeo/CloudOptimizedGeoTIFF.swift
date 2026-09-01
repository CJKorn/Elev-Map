import ElevMapCore
import Foundation

/// A ranged reader over a Cloud-Optimized GeoTIFF.
///
/// Opening costs one small read of the header; after that only the tiles that
/// intersect the requested rectangle are fetched. That is what makes it
/// reasonable to pull terrain straight from the DEM bucket on a headset
/// instead of preprocessing on a server.
public actor CloudOptimizedGeoTIFF {
    public let url: URL
    public let directories: [TIFFDirectory]
    private let reader: HTTPRangeReader

    /// Bytes fetched up front. COG headers, including overview IFDs, are
    /// expected to fit; 64 KiB is comfortable for a 1° DEM tile.
    public static let defaultHeaderSize = 64 * 1024

    public init(
        url: URL, reader: HTTPRangeReader, headerSize: Int = CloudOptimizedGeoTIFF.defaultHeaderSize
    ) async throws {
        self.url = url
        self.reader = reader
        let header = try await reader.read(url, range: 0..<headerSize)
        let parser = TIFFHeaderParser(block: header, blockOffset: 0) { range in
            try await reader.read(url, range: range)
        }
        self.directories = try await parser.parse()
    }

    /// Reads the pixels covering `bounds` as elevations in meters.
    ///
    /// The returned field is on the raster's own pixel grid, so its bounds are
    /// snapped outward to whole pixels rather than matching `bounds` exactly.
    public func heightField(for bounds: GeoBounds) async throws -> HeightField {
        let dir = directories[0]
        let window = dir.pixelWindow(for: bounds)

        var samples = [Float](
            repeating: HeightField.noData, count: window.width * window.height)

        let firstTileX = window.x / dir.tileWidth
        let lastTileX = (window.x + window.width - 1) / dir.tileWidth
        let firstTileY = window.y / dir.tileHeight
        let lastTileY = (window.y + window.height - 1) / dir.tileHeight

        // Tiles are independent; fetch and decode them concurrently.
        let decoded = try await withThrowingTaskGroup(
            of: (Int, Int, [Float]).self
        ) { group -> [(Int, Int, [Float])] in
            for ty in firstTileY...lastTileY {
                for tx in firstTileX...lastTileX {
                    group.addTask { [self] in
                        (tx, ty, try await self.tileSamples(tx: tx, ty: ty, directory: dir))
                    }
                }
            }
            let total = (lastTileY - firstTileY + 1) * (lastTileX - firstTileX + 1)
            var out: [(Int, Int, [Float])] = []
            for try await result in group {
                out.append(result)
                await ProgressReporter.refine(
                    Double(out.count) / Double(total),
                    "Read \(out.count) of \(total) raster blocks")
            }
            return out
        }

        for (tx, ty, tile) in decoded {
            let originX = tx * dir.tileWidth
            let originY = ty * dir.tileHeight
            for row in 0..<dir.tileHeight {
                let globalY = originY + row
                guard globalY >= window.y, globalY < window.y + window.height else { continue }
                for column in 0..<dir.tileWidth {
                    let globalX = originX + column
                    guard globalX >= window.x, globalX < window.x + window.width else { continue }
                    let value = tile[row * dir.tileWidth + column]
                    let destination = (globalY - window.y) * window.width + (globalX - window.x)
                    samples[destination] = value
                }
            }
        }

        let west = dir.originLongitude + Double(window.x) * dir.pixelSizeLongitude
        let east = west + Double(window.width - 1) * dir.pixelSizeLongitude
        let north = dir.originLatitude - Double(window.y) * dir.pixelSizeLatitude
        let south = north - Double(window.height - 1) * dir.pixelSizeLatitude
        let actual = GeoBounds(south: south, west: west, north: north, east: east)

        return HeightField(
            width: window.width, height: window.height, bounds: actual, samples: samples)
    }

    private func tileSamples(tx: Int, ty: Int, directory dir: TIFFDirectory) async throws -> [Float] {
        let index = ty * dir.tilesAcross + tx
        guard index >= 0, index < dir.tileOffsets.count else {
            return [Float](repeating: HeightField.noData, count: dir.tileWidth * dir.tileHeight)
        }
        let offset = Int(dir.tileOffsets[index])
        let length = Int(dir.tileByteCounts[index])
        guard length > 0 else {
            return [Float](repeating: HeightField.noData, count: dir.tileWidth * dir.tileHeight)
        }

        let raw = try await reader.read(url, range: offset..<(offset + length))
        let expected =
            dir.tileWidth * dir.tileHeight * dir.samplesPerPixel * (dir.bitsPerSample / 8)

        let decompressed = try Decompress.decompress(
            raw, compression: dir.compression, expectedSize: expected)

        var bytes = [UInt8](decompressed)
        if bytes.count < expected {
            bytes.append(contentsOf: [UInt8](repeating: 0, count: expected - bytes.count))
        }
        try Decompress.undoPredictor(
            &bytes, predictor: dir.predictor, width: dir.tileWidth, height: dir.tileHeight,
            bitsPerSample: dir.bitsPerSample, samplesPerPixel: dir.samplesPerPixel,
            littleEndian: dir.littleEndian)

        return decodeSamples(bytes, directory: dir)
    }

    private func decodeSamples(_ bytes: [UInt8], directory dir: TIFFDirectory) -> [Float] {
        let count = dir.tileWidth * dir.tileHeight
        var out = [Float](repeating: HeightField.noData, count: count)
        let stride = dir.samplesPerPixel * (dir.bitsPerSample / 8)
        let little = dir.littleEndian
        let noData = dir.noDataValue.map(Float.init)

        for i in 0..<count {
            let o = i * stride
            guard o + stride <= bytes.count else { break }
            let value: Float
            switch (dir.bitsPerSample, dir.sampleFormat) {
            case (32, 3): value = Float(bitPattern: load32(bytes, o, little))
            case (32, 2): value = Float(Int32(bitPattern: load32(bytes, o, little)))
            case (16, 2): value = Float(Int16(bitPattern: load16(bytes, o, little)))
            case (16, 1): value = Float(load16(bytes, o, little))
            default: value = HeightField.noData
            }
            // SRTM-derived products use large negative sentinels for voids.
            if let noData, value == noData {
                out[i] = HeightField.noData
            } else if value < -12_000 || value > 9_500 {
                out[i] = HeightField.noData
            } else {
                out[i] = value
            }
        }
        return out
    }

    private func load16(_ b: [UInt8], _ o: Int, _ little: Bool) -> UInt16 {
        little ? UInt16(b[o]) | UInt16(b[o + 1]) << 8 : UInt16(b[o + 1]) | UInt16(b[o]) << 8
    }

    private func load32(_ b: [UInt8], _ o: Int, _ little: Bool) -> UInt32 {
        let ordered = little ? [b[o], b[o + 1], b[o + 2], b[o + 3]] : [b[o + 3], b[o + 2], b[o + 1], b[o]]
        var v: UInt32 = 0
        for (i, byte) in ordered.enumerated() { v |= UInt32(byte) << (8 * i) }
        return v
    }
}
