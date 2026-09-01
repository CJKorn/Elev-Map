import CZLib
import ElevMapCore
import Foundation

enum Decompress {
    /// TIFF compression 1 (none), 8 and 32946 (both Deflate).
    static func decompress(
        _ input: Data, compression: UInt16, expectedSize: Int
    ) throws -> Data {
        switch compression {
        case 1: input
        case 8, 32946: try inflate(input, expectedSize: expectedSize)
        default: throw ElevMapGeoError.unsupportedCompression(compression)
        }
    }

    private static func inflate(_ input: Data, expectedSize: Int) throws -> Data {
        guard !input.isEmpty else { return Data() }

        var stream = z_stream()
        // 47 = 15 window bits + 32, which auto-detects a zlib or gzip wrapper.
        guard
            inflateInit2_(&stream, 47, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else {
            throw ElevMapError.decompressionFailed("inflateInit2 failed")
        }
        defer { inflateEnd(&stream) }

        let chunkSize = max(expectedSize, 32 * 1024)
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var output = Data(capacity: expectedSize)

        return try input.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer(
                mutating: raw.bindMemory(to: UInt8.self).baseAddress!)
            stream.avail_in = uInt(input.count)

            while true {
                let status = chunk.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return CZLib.inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 { output.append(contentsOf: chunk[0..<produced]) }

                switch status {
                case Z_STREAM_END:
                    return output
                case Z_OK, Z_BUF_ERROR:
                    if produced == 0 {
                        return output
                    }
                default:
                    throw ElevMapError.decompressionFailed("inflate returned \(status)")
                }
            }
        }
    }

    /// Undoes TIFF's floating-point predictor
    static func undoPredictor(
        _ data: inout [UInt8], predictor: Int, width: Int, height: Int,
        bitsPerSample: Int, samplesPerPixel: Int, littleEndian: Bool
    ) throws {
        guard predictor != 1 else {
            return
        }
        guard predictor == 3 else {
            throw ElevMapGeoError.corruptTile("unsupported predictor \(predictor)")
        }

        let bytesPerSample = bitsPerSample / 8
        let sampleCount = width * samplesPerPixel
        let rowBytes = sampleCount * bytesPerSample
        guard bytesPerSample > 1, rowBytes > 0, data.count >= rowBytes * height else { return }

        var row = [UInt8](repeating: 0, count: rowBytes)

        for y in 0..<height {
            let base = y * rowBytes
            for i in 1..<rowBytes {
                data[base + i] = data[base + i] &+ data[base + i - 1]
            }
            for s in 0..<sampleCount {
                for b in 0..<bytesPerSample {
                    let destination = littleEndian ? bytesPerSample - 1 - b : b
                    row[s * bytesPerSample + destination] = data[base + b * sampleCount + s]
                }
            }
            data.replaceSubrange(base..<(base + rowBytes), with: row)
        }
    }
}
