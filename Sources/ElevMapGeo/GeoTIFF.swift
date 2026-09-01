import ElevMapCore
import Foundation

/// TIFF tags this reader cares about.
enum TIFFTag: UInt16 {
    case imageWidth = 256
    case imageLength = 257
    case bitsPerSample = 258
    case compression = 259
    case stripOffsets = 273
    case samplesPerPixel = 277
    case rowsPerStrip = 278
    case stripByteCounts = 279
    case predictor = 317
    case tileWidth = 322
    case tileLength = 323
    case tileOffsets = 324
    case tileByteCounts = 325
    case sampleFormat = 339
    case modelPixelScale = 33550
    case modelTiepoint = 33922
    case gdalNoData = 42113
}

struct TIFFEntry {
    var tag: UInt16
    var type: UInt16
    var count: Int
    /// Either the value itself (when it fits in four bytes) or a file offset.
    var payload: Data

    var elementSize: Int {
        switch type {
        case 1, 2, 6, 7: 1
        case 3, 8: 2
        case 4, 9, 11: 4
        case 5, 10, 12: 8
        default: 0
        }
    }

    var byteCount: Int { elementSize * count }
    var isInline: Bool { byteCount <= 4 }
}

/// One image in the TIFF: either the full-resolution raster or an overview.
public struct TIFFDirectory: Sendable {
    public var width: Int
    public var height: Int
    public var tileWidth: Int
    public var tileHeight: Int
    public var bitsPerSample: Int
    public var sampleFormat: Int  // 1 = uint, 2 = int, 3 = IEEE float
    public var samplesPerPixel: Int
    public var compression: UInt16
    public var predictor: Int
    public var tileOffsets: [UInt64]
    public var tileByteCounts: [UInt64]
    public var noDataValue: Double?

    /// (originLon, originLat, pixelSizeLon, pixelSizeLat) in degrees.
    public var originLongitude: Double
    public var originLatitude: Double
    public var pixelSizeLongitude: Double
    public var pixelSizeLatitude: Double

    /// True when the raster is stored in strips rather than tiles; strips are
    /// treated as full-width tiles, which makes the read path uniform.
    public var isStriped: Bool
    /// Byte order of the containing file, needed to decode raw tile samples.
    public var littleEndian: Bool

    public var tilesAcross: Int { (width + tileWidth - 1) / tileWidth }
    public var tilesDown: Int { (height + tileHeight - 1) / tileHeight }

    /// Geographic rectangle covered by the whole raster.
    public var bounds: GeoBounds {
        GeoBounds(
            south: originLatitude - pixelSizeLatitude * Double(height),
            west: originLongitude,
            north: originLatitude,
            east: originLongitude + pixelSizeLongitude * Double(width))
    }

    /// Sample indices covering `area`, clamped to the raster.
    ///
    /// Inclusive of the sample on each far edge: bounds run node to node, so
    /// covering [west, east] needs `ceil - floor + 1` samples, not `ceil - floor`.
    public func pixelWindow(for area: GeoBounds) -> (x: Int, y: Int, width: Int, height: Int) {
        let x0 = Int(((area.west - originLongitude) / pixelSizeLongitude).rounded(.down))
        let x1 = Int(((area.east - originLongitude) / pixelSizeLongitude).rounded(.up))
        let y0 = Int(((originLatitude - area.north) / pixelSizeLatitude).rounded(.down))
        let y1 = Int(((originLatitude - area.south) / pixelSizeLatitude).rounded(.up))
        let cx0 = min(max(x0, 0), width - 1)
        let cy0 = min(max(y0, 0), height - 1)
        let cx1 = min(max(x1, cx0), width - 1)
        let cy1 = min(max(y1, cy0), height - 1)
        return (cx0, cy0, cx1 - cx0 + 1, cy1 - cy0 + 1)
    }
}

/// Parses the TIFF header and image file directories.
///
/// Range-driven rather than block-driven: a prefetched prefix covers the common
/// case in one request, but anything outside it — a later IFD, a long tag value
/// — is fetched on demand. DEM-S needs that: its tile-offset array alone runs to
/// about 555 KB and its first IFD ends past 800 KB.
struct TIFFHeaderParser {
    let block: Data
    let blockOffset: Int

    /// Fetches bytes that lie outside the prefetched block.
    let fetch: (Range<Int>) async throws -> Data

    private struct Entry {
        var tag: UInt16
        var type: UInt16
        var count: Int
        /// Inline value bytes, or the offset where the value lives.
        var inlineBytes: Data?
        var valueOffset: Int
    }

    func parse() async throws -> [TIFFDirectory] {
        guard block.count >= 16 else { throw ElevMapGeoError.notATIFF }
        let signature = [UInt8](block.prefix(4))
        let littleEndian: Bool
        switch (signature[0], signature[1]) {
        case (0x49, 0x49): littleEndian = true
        case (0x4D, 0x4D): littleEndian = false
        default: throw ElevMapGeoError.notATIFF
        }

        var reader = ByteReader(block, littleEndian: littleEndian, offset: 2)
        let magic = try reader.readUInt16()

        // Classic TIFF and BigTIFF differ only in how wide the counts and
        // offsets are; everything downstream is shared.
        let big: Bool
        var next: Int
        switch magic {
        case 42:
            big = false
            next = Int(try reader.readUInt32())
        case 43:
            big = true
            guard try reader.readUInt16() == 8 else {
                throw ElevMapGeoError.unsupportedBigTIFFOffsetSize
            }
            _ = try reader.readUInt16()  // reserved, always zero
            next = Int(try reader.readUInt64())
        default:
            throw ElevMapGeoError.notATIFF
        }

        var directories: [TIFFDirectory] = []
        var seen = Set<Int>()

        while next != 0, !seen.contains(next), directories.count < 32 {
            seen.insert(next)
            let (entries, following) = try await readDirectory(
                at: next, big: big, littleEndian: littleEndian)
            next = following
            if let directory = try await makeDirectory(
                entries: entries, littleEndian: littleEndian, big: big)
            {
                directories.append(directory)
            }
        }

        guard !directories.isEmpty else {
            throw ElevMapGeoError.missingTag(TIFFTag.imageWidth.rawValue)
        }
        return directories
    }

    private func readDirectory(
        at offset: Int, big: Bool, littleEndian: Bool
    ) async throws -> ([UInt16: Entry], Int) {
        let countSize = big ? 8 : 2
        let entrySize = big ? 20 : 12
        let inlineCapacity = big ? 8 : 4

        let countBytes = try await bytes(at: offset, count: countSize)
        var countReader = ByteReader(countBytes, littleEndian: littleEndian)
        let count = big ? Int(try countReader.readUInt64()) : Int(try countReader.readUInt16())
        guard count > 0, count < 4096 else {
            throw ElevMapGeoError.malformedDirectory("implausible entry count \(count)")
        }

        let table = try await bytes(
            at: offset + countSize, count: count * entrySize + (big ? 8 : 4))
        var entries: [UInt16: Entry] = [:]
        for i in 0..<count {
            var reader = ByteReader(table, littleEndian: littleEndian, offset: i * entrySize)
            let tag = try reader.readUInt16()
            let type = try reader.readUInt16()
            let valueCount = big ? Int(try reader.readUInt64()) : Int(try reader.readUInt32())
            let valueField = try reader.readBytes(inlineCapacity)

            let byteCount = TIFFValue.size(of: type) * valueCount
            if byteCount <= inlineCapacity {
                entries[tag] = Entry(
                    tag: tag, type: type, count: valueCount, inlineBytes: valueField,
                    valueOffset: 0)
            } else {
                var offsetReader = ByteReader(valueField, littleEndian: littleEndian)
                let valueOffset =
                    big ? Int(try offsetReader.readUInt64()) : Int(try offsetReader.readUInt32())
                entries[tag] = Entry(
                    tag: tag, type: type, count: valueCount, inlineBytes: nil,
                    valueOffset: valueOffset)
            }
        }

        var nextReader = ByteReader(
            table, littleEndian: littleEndian, offset: count * entrySize)
        let following = big ? Int(try nextReader.readUInt64()) : Int(try nextReader.readUInt32())
        return (entries, following)
    }

    private func bytes(at offset: Int, count: Int) async throws -> Data {
        let local = offset - blockOffset
        if local >= 0, local + count <= block.count {
            let start = block.startIndex + local
            return block[start..<(start + count)]
        }
        return try await fetch(offset..<(offset + count))
    }

    private func payload(_ entry: Entry) async throws -> Data {
        let size = TIFFValue.size(of: entry.type) * entry.count
        if let inline = entry.inlineBytes { return inline.prefix(max(size, 1)) }
        return try await bytes(at: entry.valueOffset, count: size)
    }

    private func makeDirectory(
        entries: [UInt16: Entry], littleEndian: Bool, big: Bool
    ) async throws -> TIFFDirectory? {
        func ints(_ tag: TIFFTag) async throws -> [UInt64]? {
            guard let e = entries[tag.rawValue] else { return nil }
            return TIFFValue.integers(
                try await payload(e), type: e.type, count: e.count, littleEndian: littleEndian)
        }
        func doubles(_ tag: TIFFTag) async throws -> [Double]? {
            guard let e = entries[tag.rawValue] else { return nil }
            return TIFFValue.doubles(
                try await payload(e), type: e.type, count: e.count, littleEndian: littleEndian)
        }

        guard let width = try await ints(.imageWidth)?.first,
            let height = try await ints(.imageLength)?.first
        else { return nil }

        let bits = Int(try await ints(.bitsPerSample)?.first ?? 8)
        let format = Int(try await ints(.sampleFormat)?.first ?? 1)
        let samples = Int(try await ints(.samplesPerPixel)?.first ?? 1)
        let compression = UInt16(try await ints(.compression)?.first ?? 1)
        let predictor = Int(try await ints(.predictor)?.first ?? 1)

        let tileW = try await ints(.tileWidth)?.first
        let tileH = try await ints(.tileLength)?.first
        let striped = tileW == nil

        // Tiled and striped layouts use different tags for the same thing.
        var offsets = try await ints(.tileOffsets)
        if offsets == nil { offsets = try await ints(.stripOffsets) }
        var counts = try await ints(.tileByteCounts)
        if counts == nil { counts = try await ints(.stripByteCounts) }
        let tileOffsets = offsets ?? []
        let tileByteCounts = counts ?? []
        guard !tileOffsets.isEmpty, tileOffsets.count == tileByteCounts.count else {
            throw ElevMapGeoError.missingTag(TIFFTag.tileOffsets.rawValue)
        }

        let rowsPerStrip = try await ints(.rowsPerStrip)?.first ?? height
        let scale = try await doubles(.modelPixelScale) ?? [1, 1, 0]
        let tie = try await doubles(.modelTiepoint) ?? [0, 0, 0, 0, 0, 0]

        var noData: Double?
        if let e = entries[TIFFTag.gdalNoData.rawValue] {
            let text = String(decoding: try await payload(e), as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0 \n\r\t"))
            noData = Double(text)
        }

        // Tiepoint maps raster point (i, j) to model point (x, y).
        let originLon = tie.count >= 4 ? tie[3] - tie[0] * scale[0] : 0
        let originLat = tie.count >= 5 ? tie[4] + tie[1] * scale[1] : 0

        return TIFFDirectory(
            width: Int(width), height: Int(height),
            tileWidth: Int(tileW ?? width), tileHeight: Int(tileH ?? rowsPerStrip),
            bitsPerSample: bits, sampleFormat: format, samplesPerPixel: samples,
            compression: compression, predictor: predictor,
            tileOffsets: tileOffsets, tileByteCounts: tileByteCounts, noDataValue: noData,
            originLongitude: originLon, originLatitude: originLat,
            pixelSizeLongitude: scale[0], pixelSizeLatitude: scale.count > 1 ? scale[1] : scale[0],
            isStriped: striped, littleEndian: littleEndian)
    }
}

enum TIFFValue {
    static func size(of type: UInt16) -> Int {
        switch type {
        case 1, 2, 6, 7: 1
        case 3, 8: 2
        case 4, 9, 11: 4
        case 5, 10, 12, 16, 17, 18: 8
        default: 1
        }
    }

    static func integers(
        _ data: Data, type: UInt16, count: Int, littleEndian: Bool
    ) -> [UInt64] {
        var reader = ByteReader(data, littleEndian: littleEndian)
        var out: [UInt64] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            switch type {
            case 1, 2, 6, 7: guard let v = try? reader.readUInt8() else { return out }
                out.append(UInt64(v))
            case 3, 8: guard let v = try? reader.readUInt16() else { return out }
                out.append(UInt64(v))
            case 4, 9: guard let v = try? reader.readUInt32() else { return out }
                out.append(UInt64(v))
            case 16, 17: guard let v = try? reader.readUInt64() else { return out }
                out.append(v)
            default: return out
            }
        }
        return out
    }

    static func doubles(
        _ data: Data, type: UInt16, count: Int, littleEndian: Bool
    ) -> [Double] {
        var reader = ByteReader(data, littleEndian: littleEndian)
        var out: [Double] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            switch type {
            case 11: guard let v = try? reader.readFloat() else { return out }
                out.append(Double(v))
            case 12: guard let v = try? reader.readDouble() else { return out }
                out.append(v)
            case 5, 10:
                guard let n = try? reader.readUInt32(), let d = try? reader.readUInt32()
                else { return out }
                out.append(d == 0 ? 0 : Double(n) / Double(d))
            default:
                return integers(data, type: type, count: count, littleEndian: littleEndian)
                    .map(Double.init)
            }
        }
        return out
    }
}
