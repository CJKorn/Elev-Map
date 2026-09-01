import ElevMapCore
import Foundation

public protocol TileCache: Sendable {
    func data(forKey key: String) async -> Data?
    func store(_ data: Data, forKey key: String) async
}

public struct CachingRangeReader: HTTPRangeReader {
    private let upstream: HTTPRangeReader
    private let cache: TileCache

    public init(upstream: HTTPRangeReader, cache: TileCache) {
        self.upstream = upstream
        self.cache = cache
    }

    public func read(_ url: URL, range: Range<Int>?) async throws -> Data {
        let key: String
        if let range {
            key = "\(url.absoluteString)#\(range.lowerBound)-\(range.upperBound)"
        } else {
            key = url.absoluteString
        }
        if let hit = await cache.data(forKey: key) { return hit }
        let data = try await upstream.read(url, range: range)
        await cache.store(data, forKey: key)
        return data
    }
}

public actor FileTileCache: TileCache {
    private let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(forKey key: String) -> URL {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return directory.appendingPathComponent(String(hash, radix: 16), isDirectory: false)
    }

    public func data(forKey key: String) async -> Data? {
        try? Data(contentsOf: fileURL(forKey: key))
    }

    public func store(_ data: Data, forKey key: String) async {
        try? data.write(to: fileURL(forKey: key), options: .atomic)
    }
}
