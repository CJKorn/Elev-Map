import ElevMapCore
import Foundation

// For visionOS and Linux, FoundationNetworking is needed for URLSession.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public struct URLSessionRangeReader: HTTPRangeReader {
    private let session: URLSession
    private let extraHeaders: [String: String]

    public init(session: URLSession = .shared, extraHeaders: [String: String] = [:]) {
        self.session = session
        self.extraHeaders = extraHeaders
    }

    public func read(_ url: URL, range: Range<Int>?) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)",
                forHTTPHeaderField: "Range")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ElevMapError.malformedResponse("no HTTP response for \(url.absoluteString)")
        }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            throw ElevMapError.httpStatus(http.statusCode, url)
        }
        if let range, http.statusCode == 200, data.count > range.count {
            return data.subdata(in: range.lowerBound..<min(range.upperBound, data.count))
        }
        return data
    }
}
