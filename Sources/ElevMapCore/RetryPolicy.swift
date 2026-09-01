import Foundation

/// Exponential backoff with jitter, for operations that fail transiently.
public struct RetryPolicy: Sendable {
    /// Total attempts including the first. 1 disables retrying.
    public var maxAttempts: Int
    public var initialDelay: Duration
    public var multiplier: Double
    public var maximumDelay: Duration
    /// Fraction of each delay randomised, so clients that hit the same outage
    /// do not retry in lockstep.
    public var jitter: Double

    public init(
        maxAttempts: Int = 3,
        initialDelay: Duration = .milliseconds(400),
        multiplier: Double = 2.5,
        maximumDelay: Duration = .seconds(8),
        jitter: Double = 0.3
    ) {
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maximumDelay = maximumDelay
        self.jitter = jitter
    }

    public static let none = RetryPolicy(maxAttempts: 1)

    public func delay(beforeAttempt attempt: Int) -> Duration {
        guard attempt > 1 else { return .zero }
        var seconds = initialDelay.seconds * pow(multiplier, Double(attempt - 2))
        seconds = min(seconds, maximumDelay.seconds)
        if jitter > 0 { seconds *= 1 + Double.random(in: -jitter...jitter) }
        return .milliseconds(Int(max(0, seconds) * 1000))
    }

    public func run<T: Sendable>(
        isRetryable: (any Error) -> Bool = RetryPolicy.isTransient,
        operation: () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A cancelled task must stop, not back off and try again.
                try Task.checkCancellation()
                guard attempt < maxAttempts, isRetryable(error) else { throw error }
                attempt += 1
                try await Task.sleep(for: delay(beforeAttempt: attempt))
            }
        }
    }

    /// Retries server-side and transport failures, but not a request the
    /// server has told us is wrong: a 404 will still be a 404 next time.
    public static func isTransient(_ error: any Error) -> Bool {
        guard let mapError = error as? ElevMapError else {
            // Transport failures arrive as opaque URLError or NIO errors.
            return true
        }
        switch mapError {
        case .httpStatus(let code, _):
            return code == 408 || code == 425 || code == 429 || (500...599).contains(code)
        case .malformedResponse:
            return true
        default:
            return false
        }
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
