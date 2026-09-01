import Foundation

/// How far a terrain build has got.
public struct TerrainProgress: Sendable, Codable {
    /// 0...1 across the whole build.
    public var fraction: Double
    /// Which part of the build produced this update, e.g. "elevation".
    public var channel: String
    public var message: String

    public init(fraction: Double, channel: String, message: String) {
        self.fraction = fraction
        self.channel = channel
        self.message = message
    }
}

/// Aggregates progress from the concurrent halves of a build into one bar.
///
/// Sources report into a channel without knowing what else is running or what
/// their part is worth; the reporter owns the weights and the sum. It reaches
/// them through a task local rather than a parameter so `ElevationSource` and
/// `ImagerySource` stay single-method protocols — and because elevation and
/// imagery run as sibling child tasks, which inherit task locals for free.
public actor ProgressReporter {
    /// Nil outside a build, which is what makes every `report` call a no-op
    /// when nobody asked for progress.
    @TaskLocal public static var current: ProgressReporter?
    @TaskLocal public static var channel: String = "work"
    /// The slice of the current channel that work in this task owns. Nil
    /// means nobody has granted one, and finer-grained reporting stays quiet
    /// rather than filling the whole channel.
    @TaskLocal public static var span: ClosedRange<Double>?
    /// Set when the span belongs to a single request, so a reader that can see
    /// Content-Length may report the download inside it.
    @TaskLocal public static var spanIsOneRequest: Bool = false

    private let handler: @Sendable (TerrainProgress) -> Void
    private var weights: [String: Double]
    private var fractions: [String: Double] = [:]
    private var highWaterMark: Double = 0

    /// - Parameter weights: how much of the bar each channel is worth,
    ///   relative to the others. Channels not named here are ignored.
    public init(
        weights: [String: Double],
        handler: @escaping @Sendable (TerrainProgress) -> Void
    ) {
        self.weights = weights
        self.handler = handler
    }

    public func update(_ channel: String, fraction: Double, message: String) {
        guard let total = totalWeight, weights[channel] != nil else { return }
        // Channels only move forwards, so a retry cannot walk the bar back.
        fractions[channel] = max(fractions[channel] ?? 0, min(max(fraction, 0), 1))

        let done = weights.reduce(0.0) { $0 + $1.value * (fractions[$1.key] ?? 0) }
        highWaterMark = max(highWaterMark, done / total)
        handler(
            TerrainProgress(fraction: highWaterMark, channel: channel, message: message))
    }

    private var totalWeight: Double? {
        let sum = weights.values.reduce(0, +)
        return sum > 0 ? sum : nil
    }
}

extension ProgressReporter {
    /// Runs `body` with everything inside it reporting into `channel`.
    public static func run<T>(
        channel: String, _ body: () async throws -> T
    ) async rethrows -> T {
        try await $channel.withValue(channel) {
            try await $span.withValue(nil) {
                try await $spanIsOneRequest.withValue(false) {
                    try await body()
                }
            }
        }
    }

    /// Reports a fraction of the current channel, or of the open span.
    public static func report(_ fraction: Double, _ message: String) async {
        guard let reporter = current else { return }
        var value = fraction
        if let span {
            value = span.lowerBound + fraction * (span.upperBound - span.lowerBound)
        }
        await reporter.update(channel, fraction: value, message: message)
    }

    /// Reports inside an open span, and does nothing without one.
    ///
    /// What library internals call. A COG does not know whether it is the
    /// whole of a build's elevation or one of four tiles being read at once,
    /// so it only speaks when a caller has handed it a slice of the bar.
    public static func refine(_ fraction: Double, _ message: String) async {
        guard span != nil else { return }
        await report(fraction, message)
    }

    /// Hands `range` of the current channel to `body`, which reports 0...1
    /// within it. Ranges nest.
    ///
    /// Never open one around concurrent work: the children would each drive
    /// the same slice and the bar would jump between them.
    public static func spanning<T>(
        _ range: ClosedRange<Double>,
        oneRequest: Bool = false,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let outer = span ?? 0...1
        let width = outer.upperBound - outer.lowerBound
        let lower = outer.lowerBound + range.lowerBound * width
        let upper = outer.lowerBound + range.upperBound * width
        return try await $span.withValue(lower...upper) {
            try await $spanIsOneRequest.withValue(oneRequest) {
                try await body()
            }
        }
    }
}
