import Foundation

/// Grid of elevations in meters over GeoBounds
/// Row 0 is the north edge
public struct HeightField: Sendable {
    public let width: Int
    public let height: Int
    public let bounds: GeoBounds
    public private(set) var samples: [Float]

    /// Set elevation to lowest possible value to indicate no data.
    public static let noData: Float = -.greatestFiniteMagnitude

    public init(width: Int, height: Int, bounds: GeoBounds, samples: [Float]) {
        precondition(samples.count == width * height, "sample count must equal width * height")
        self.width = width
        self.height = height
        self.bounds = bounds
        self.samples = samples
    }

    public init(width: Int, height: Int, bounds: GeoBounds, repeating value: Float = 0) {
        self.init(
            width: width, height: height, bounds: bounds,
            samples: [Float](repeating: value, count: width * height))
    }

    /// Get value at coordinates
    public subscript(x: Int, y: Int) -> Float {
        get { samples[y * width + x] }
        set { samples[y * width + x] = newValue }
    }

    public var elevationRange: ClosedRange<Float> {
        var lo = Float.greatestFiniteMagnitude
        var hi = -Float.greatestFiniteMagnitude
        for s in samples where s != Self.noData {
            lo = min(lo, s)
            hi = max(hi, s)
        }
        if lo <= hi {
            return lo...hi
        }
        else {
            return 0...0
        }
    }

    /// Replaces invalid samples with the mean of valid samples, not a good fix _-_
    public mutating func fixNull() {
        var sum: Double = 0
        var count = 0
        for s in samples where s != Self.noData {
            sum += Double(s)
            count += 1
        }
        guard count < samples.count else { return }
        let mean = count > 0 ? Float(sum / Double(count)) : 0
        for i in samples.indices where samples[i] == Self.noData {
            samples[i] = mean
        }
    }

    public func nearestSample(u: Double, v: Double) -> Float {
        let x = Int((min(max(u, 0), 1) * Double(width - 1)).rounded())
        let y = Int((min(max(v, 0), 1) * Double(height - 1)).rounded())
        return self[x, y]
    }
}
