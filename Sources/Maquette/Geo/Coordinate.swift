import CoreLocation
import Foundation

/// A point on the earth: longitude, latitude, and an optional altitude in metres.
///
/// This is the library's GeoJSON *position*. It is named `Coordinate` rather than `Position`
/// because "position" already means a point in diorama space throughout the rest of Maquette, and
/// the two must never be confused — a `Coordinate` is somewhere on the earth, a `SIMD3<Float>`
/// position is somewhere on the table.
///
/// **Longitude comes first when this type is encoded**, per RFC 7946 §3.1.1, which is the opposite
/// order from `CLLocationCoordinate2D` and from the `init(latitude:longitude:)` most call sites
/// use. Both spellings are provided with explicit argument labels precisely so that neither can be
/// written by accident; the ordering trap only exists at the JSON boundary, and that is handled
/// here once.
///
/// Measurement lives in ``Turf`` rather than on this type. A coordinate is a place, not a ruler:
/// "how far apart" and "what is over there" depend on an earth model, and stating that choice at
/// the call site is better than burying one sphere in the value type and a different ellipsoid in
/// the projection.
public struct Coordinate: Sendable, Hashable {
    /// Longitude in degrees, positive east of the prime meridian.
    public var longitude: Double
    /// Latitude in degrees, positive north of the equator.
    public var latitude: Double
    /// Height above the WGS84 ellipsoid in metres, or `nil` when the position carries none.
    ///
    /// GeoJSON positions may be two or three dimensional, and the difference is meaningful: a
    /// feature with no altitude is one that should be clamped to whatever ground it lands on, and a
    /// feature with `0` is one that sits at ellipsoid height zero. Collapsing the two would make
    /// every unadorned point sink to sea level.
    public var altitude: Double?

    /// Creates a coordinate in latitude/longitude order.
    public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
        self.longitude = longitude
        self.latitude = latitude
        self.altitude = altitude
    }

    /// Creates a coordinate in GeoJSON's longitude/latitude order.
    public init(longitude: Double, latitude: Double, altitude: Double? = nil) {
        self.longitude = longitude
        self.latitude = latitude
        self.altitude = altitude
    }

    /// Creates a coordinate from a `CLLocationCoordinate2D`.
    public init(_ clCoordinate: CLLocationCoordinate2D, altitude: Double? = nil) {
        self.longitude = clCoordinate.longitude
        self.latitude = clCoordinate.latitude
        self.altitude = altitude
    }

    /// Converts to a `CLLocationCoordinate2D`, dropping any altitude.
    public var clLocationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Latitude in radians.
    public var latitudeRadians: Double {
        latitude * .pi / 180
    }

    /// Longitude in radians.
    public var longitudeRadians: Double {
        longitude * .pi / 180
    }

    /// The same place with its altitude removed.
    public var horizontal: Coordinate {
        Coordinate(longitude: longitude, latitude: latitude)
    }

    /// The same place at the given height above the ellipsoid.
    public func at(altitude: Double?) -> Coordinate {
        Coordinate(longitude: longitude, latitude: latitude, altitude: altitude)
    }
}

extension Coordinate: CustomStringConvertible {
    /// Labelled rather than bare, so a printed coordinate cannot be misread in the other order.
    public var description: String {
        let place = String(format: "(lat: %0.6f, lon: %0.6f", latitude, longitude)
        guard let altitude else { return place + ")" }
        return place + String(format: ", alt: %0.2f)", altitude)
    }
}

// MARK: - GeoJSON representation

extension Coordinate: Codable {
    /// Decodes a GeoJSON position: `[longitude, latitude]` or `[longitude, latitude, altitude]`.
    ///
    /// Positions longer than three elements are accepted and their extra elements discarded, which
    /// is what RFC 7946 §3.1.1 requires of a parser that does not understand them.
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        guard let count = container.count, count >= 2 else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "A GeoJSON position needs at least a longitude and a latitude"
                )
            )
        }
        longitude = try container.decode(Double.self)
        latitude = try container.decode(Double.self)
        altitude = count >= 3 ? try container.decode(Double.self) : nil
        while !container.isAtEnd {
            _ = try container.decode(Double.self)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(longitude)
        try container.encode(latitude)
        if let altitude {
            try container.encode(altitude)
        }
    }
}
