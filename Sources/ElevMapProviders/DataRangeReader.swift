import ElevMapCore
import Foundation

public struct DataRangeReader: HTTPRangeReader {
    private let data: Data

    public init(_ data: Data) {
        self.data = data
    }

    public func read(_ url: URL, range: Range<Int>?) async throws -> Data {
        guard let range else { return data }
        let lower = min(max(range.lowerBound, 0), data.count)
        let upper = min(max(range.upperBound, lower), data.count)
        let start = data.startIndex
        return data[(start + lower)..<(start + upper)]
    }
}
