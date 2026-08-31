import Foundation

/// Standard geographic coordinate in degrees
public struct GeoCoordinate: Hashable, Sendable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// An axis-aligned latitude/longitude rectangle.
/// On visionOS this is produced from an `MKMapRect`
public struct GeoBounds: Hashable, Sendable, Codable {
    public var south: Double
    public var west: Double
    public var north: Double
    public var east: Double

    public init(south: Double, west: Double, north: Double, east: Double) {
        self.south = south
        self.west = west
        self.north = north
        self.east = east
    }

    public var center: GeoCoordinate {
        GeoCoordinate(latitude: (south + north) / 2, longitude: (west + east) / 2)
    }

    public var latitudeSpan: Double { north - south }
    public var longitudeSpan: Double { east - west }

    public var isValid: Bool {
        north > south && east > west
            && south >= -90 && north <= 90
            && west >= -180 && east <= 180
    }
}

/// For converting geographic coordinates to a local east/north/up frame in meters from an origin.
public struct LocalENU: Sendable, Codable {
    public var origin: GeoCoordinate

    public init(origin: GeoCoordinate) {
        self.origin = origin
    }

    public var metersPerDegreeLatitude: Double {
        let phi = origin.latitude * .pi / 180
        return 111_132.92 - 559.82 * cos(2 * phi) + 1.175 * cos(4 * phi) - 0.0023 * cos(6 * phi)
    }

    public var metersPerDegreeLongitude: Double {
        let phi = origin.latitude * .pi / 180
        return 111_412.84 * cos(phi) - 93.5 * cos(3 * phi) + 0.118 * cos(5 * phi)
    }

    /// Converts a geographic coordinate to a local east/north/up frame in meters
    public func project(_ c: GeoCoordinate) -> SIMD2<Double> {
        SIMD2(
            (c.longitude - origin.longitude) * metersPerDegreeLongitude,
            (c.latitude - origin.latitude) * metersPerDegreeLatitude)
    }

    /// Reverse of project()
    public func unproject(_ meters: SIMD2<Double>) -> GeoCoordinate {
        GeoCoordinate(
            latitude: origin.latitude + meters.y / metersPerDegreeLatitude,
            longitude: origin.longitude + meters.x / metersPerDegreeLongitude)
    }
}