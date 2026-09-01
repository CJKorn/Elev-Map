import Foundation

/// In the VROC this may be written (already existing) somewhere else
struct ByteReader {
    let data: Data
    let littleEndian: Bool
    private(set) var offset: Int

    init(_ data: Data, littleEndian: Bool = true, offset: Int = 0) {
        self.data = data
        self.littleEndian = littleEndian
        self.offset = offset
    }

    var remaining: Int { data.count - offset }

    mutating func seek(to newOffset: Int) throws {
        guard newOffset >= 0, newOffset <= data.count else {
            throw ElevMapGeoError.truncated(needed: newOffset, available: data.count)
        }
        offset = newOffset
    }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard remaining >= count else {
            throw ElevMapGeoError.truncated(needed: offset + count, available: data.count)
        }
        let start = data.startIndex + offset
        defer { offset += count }
        return data[start..<(start + count)]
    }

    mutating func readUInt8() throws -> UInt8 { try readBytes(1).first! }

    mutating func readUInt16() throws -> UInt16 {
        let b = [UInt8](try readBytes(2))
        return littleEndian
            ? UInt16(b[0]) | UInt16(b[1]) << 8
            : UInt16(b[1]) | UInt16(b[0]) << 8
    }

    mutating func readUInt32() throws -> UInt32 {
        let b = [UInt8](try readBytes(4))
        let ordered = littleEndian ? b : b.reversed()
        var v: UInt32 = 0
        for (i, byte) in ordered.enumerated() { v |= UInt32(byte) << (8 * i) }
        return v
    }

    mutating func readUInt64() throws -> UInt64 {
        let b = [UInt8](try readBytes(8))
        let ordered = littleEndian ? b : b.reversed()
        var v: UInt64 = 0
        for (i, byte) in ordered.enumerated() { v |= UInt64(byte) << (8 * i) }
        return v
    }

    mutating func readFloat() throws -> Float { Float(bitPattern: try readUInt32()) }
    mutating func readDouble() throws -> Double { Double(bitPattern: try readUInt64()) }
}

public enum ElevMapGeoError: Error, CustomStringConvertible {
    case notATIFF
    case unsupportedBigTIFFOffsetSize
    case malformedDirectory(String)
    case truncated(needed: Int, available: Int)
    case missingTag(UInt16)
    case unsupportedCompression(UInt16)
    case unsupportedSampleFormat(bitsPerSample: Int, sampleFormat: Int)
    case corruptTile(String)

    public var description: String {
        switch self {
        case .notATIFF: "Not a TIFF file"
        case .unsupportedBigTIFFOffsetSize: "BigTIFF with a non-8-byte offset size"
        case .malformedDirectory(let detail): "Malformed image file directory: \(detail)"
        case .truncated(let needed, let available):
            "Truncated data: needed byte \(needed), have \(available)"
        case .missingTag(let tag): "Missing required TIFF tag \(tag)"
        case .unsupportedCompression(let c): "Unsupported TIFF compression \(c)"
        case .unsupportedSampleFormat(let bits, let format):
            "Unsupported sample format: \(bits) bits, format \(format)"
        case .corruptTile(let detail): "Corrupt tile: \(detail)"
        }
    }
}
