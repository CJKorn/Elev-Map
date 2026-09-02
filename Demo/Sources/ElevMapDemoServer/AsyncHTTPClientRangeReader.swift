import AsyncHTTPClient
import ElevMapCore
import Foundation
import NIOCore

/// `HTTPRangeReader` on NIO's HTTP client, for the demo server only.
///
/// The library's `URLSessionRangeReader` is the path that ships to the
/// headset, where URLSession is Apple's implementation. On Linux it is
/// swift-corelibs-foundation's, whose header parser rejects a response header
/// with an empty value — which SIX Maps sends (`Server: ` followed by a single
/// space), failing every request to that host including small JSON ones.
/// NIO's parser accepts it.
///
/// Worth keeping in the demo package rather than the library: it is a
/// workaround for a server-side Linux quirk, not something the device needs.
struct AsyncHTTPClientRangeReader: HTTPRangeReader {
    /// Guards against a runaway response filling memory.
    var maximumResponseBytes = 128 * 1024 * 1024
    /// SIX Maps renders each distinct request from scratch, which can take
    /// half a minute before a byte arrives.
    var timeout = TimeAmount.seconds(300)
    /// Extra request headers, e.g. the User-Agent the OSM tile policy asks for.
    var headers: [String: String] = [:]

    init(headers: [String: String] = [:]) {
        self.headers = headers
    }

    func read(_ url: URL, range: Range<Int>?) async throws -> Data {
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .GET
        for (name, value) in headers {
            request.headers.add(name: name, value: value)
        }
        if let range {
            request.headers.add(name: "Range", value: "bytes=\(range.lowerBound)-\(range.upperBound - 1)")
        }

        let response = try await HTTPClient.shared.execute(request, timeout: timeout)
        guard response.status == .ok || response.status == .partialContent else {
            throw ElevMapError.httpStatus(Int(response.status.code), url)
        }

        let expected = response.headers.first(name: "content-length").flatMap(Int.init)
        let data = try await collect(response.body, expected: expected)
        // A server that ignores the Range header returns the whole file.
        if let range, response.status == .ok, data.count > range.count {
            return data.subdata(in: range.lowerBound..<min(range.upperBound, data.count))
        }
        return data
    }

    /// Streams the body when a source has said this request owns its slice of
    /// the bar and the server told us how long the response is — the
    /// exportImage requests, which are one slow download each. Everything
    /// else, including the many small COG range reads, takes the plain path.
    private func collect(
        _ body: HTTPClientResponse.Body, expected: Int?
    ) async throws -> Data {
        guard ProgressReporter.spanIsOneRequest, let expected, expected > 256 * 1024 else {
            return Data(try await body.collect(upTo: maximumResponseBytes).readableBytesView)
        }

        var data = Data(capacity: min(expected, maximumResponseBytes))
        var lastReported = 0
        for try await chunk in body {
            data.append(contentsOf: chunk.readableBytesView)
            guard data.count <= maximumResponseBytes else {
                throw ElevMapError.malformedResponse("response exceeded \(maximumResponseBytes) bytes")
            }
            // One report per 2%, not one per chunk: a 5 MB image arrives in
            // hundreds of pieces and each report hops to another actor.
            if data.count - lastReported >= expected / 50 {
                lastReported = data.count
                await ProgressReporter.report(
                    Double(data.count) / Double(expected),
                    "Downloading \(megabytes(data.count)) of \(megabytes(expected))")
            }
        }
        return data
    }

    private func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
