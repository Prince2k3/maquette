import Foundation

/// An axis-aligned geographic extent: the smallest longitude/latitude rectangle containing
/// something.
///
/// **A box may cross the antimeridian, and then `west` is greater than `east`.** RFC 7946 §5.2
/// specifies exactly that, and it is the one thing about bounding boxes that is easy to get wrong:
/// a containment test written as `west <= longitude && longitude <= east` silently reports *every*
/// point outside such a box, so a diorama over Fiji finds nothing. The tests here go through
/// ``contains(_:)`` and ``intersects(_:)``, which split the span in two when it wraps.
///
/// Encoded as `[west, south, east, north]`, or `[west, south, minimumAltitude, east, north,
/// maximumAltitude]` when altitudes are present — all axes of the southwesterly point followed by
/// all axes of the northeasterly one.
public struct GeographicBounds: Sendable, Hashable {
    /// The westerly longitude in degrees. Greater than ``east`` when the box crosses the
    /// antimeridian.
    public var west: Double
    /// The southerly latitude in degrees.
    public var south: Double
    /// The easterly longitude in degrees.
    public var east: Double
    /// The northerly latitude in degrees.
    public var north: Double
    /// The lowest altitude in metres, if the box is three dimensional.
    public var minimumAltitude: Double?
    /// The highest altitude in metres, if the box is three dimensional.
    public var maximumAltitude: Double?

    public init(
        west: Double,
        south: Double,
        east: Double,
        north: Double,
        minimumAltitude: Double? = nil,
        maximumAltitude: Double? = nil
    ) {
        self.west = west
        self.south = south
        self.east = east
        self.north = north
        self.minimumAltitude = minimumAltitude
        self.maximumAltitude = maximumAltitude
    }

    /// The box enclosing the given positions, or `nil` if there are none.
    ///
    /// This never produces a wrapped box: a set of positions either side of the antimeridian is
    /// enclosed the long way round, because nothing here can tell "two points near the dateline"
    /// apart from "two points on opposite sides of the world". RFC 7946 §5.2 asks a *writer* to
    /// wrap deliberately; a reader cannot infer the intent.
    public init?(enclosing coordinates: some Sequence<Coordinate>) {
        var iterator = coordinates.makeIterator()
        guard let first = iterator.next() else { return nil }

        west = first.longitude
        east = first.longitude
        south = first.latitude
        north = first.latitude
        minimumAltitude = first.altitude
        maximumAltitude = first.altitude

        while let coordinate = iterator.next() {
            west = min(west, coordinate.longitude)
            east = max(east, coordinate.longitude)
            south = min(south, coordinate.latitude)
            north = max(north, coordinate.latitude)
            if let altitude = coordinate.altitude {
                minimumAltitude = min(minimumAltitude ?? altitude, altitude)
                maximumAltitude = max(maximumAltitude ?? altitude, altitude)
            }
        }
    }

    /// Whether the box's longitude span crosses the antimeridian.
    public var crossesAntimeridian: Bool {
        west > east
    }

    /// The middle of the box, following the shorter way round when it wraps.
    public var center: Coordinate {
        let longitude: Double
        if crossesAntimeridian {
            let middle = west + (east + 360 - west) / 2
            longitude = middle > 180 ? middle - 360 : middle
        } else {
            longitude = (west + east) / 2
        }
        return Coordinate(longitude: longitude, latitude: (south + north) / 2)
    }

    /// The box's four corners, starting southwest and running counterclockwise.
    public var corners: [Coordinate] {
        [
            Coordinate(longitude: west, latitude: south),
            Coordinate(longitude: east, latitude: south),
            Coordinate(longitude: east, latitude: north),
            Coordinate(longitude: west, latitude: north),
        ]
    }

    /// Whether the coordinate falls inside the box, edges included.
    public func contains(_ coordinate: Coordinate) -> Bool {
        guard coordinate.latitude >= south, coordinate.latitude <= north else { return false }
        return containsLongitude(coordinate.longitude)
    }

    /// Whether the two boxes overlap at all, edges included.
    public func intersects(_ other: GeographicBounds) -> Bool {
        guard north >= other.south, other.north >= south else { return false }
        return longitudeSpans.contains { span in
            other.longitudeSpans.contains { $0.lowerBound <= span.upperBound && span.lowerBound <= $0.upperBound }
        }
    }

    /// Whether the box wholly encloses another, edges included.
    public func contains(_ other: GeographicBounds) -> Bool {
        guard other.south >= south, other.north <= north else { return false }
        return other.longitudeSpans.allSatisfy { span in
            longitudeSpans.contains { $0.lowerBound <= span.lowerBound && span.upperBound <= $0.upperBound }
        }
    }

    /// The box enclosing both, taken the unwrapped way round.
    public func union(_ other: GeographicBounds) -> GeographicBounds {
        GeographicBounds(
            west: min(west, other.west),
            south: min(south, other.south),
            east: max(east, other.east),
            north: max(north, other.north),
            minimumAltitude: [minimumAltitude, other.minimumAltitude].compactMap { $0 }.min(),
            maximumAltitude: [maximumAltitude, other.maximumAltitude].compactMap { $0 }.max()
        )
    }

    /// The box's longitude extent as one span, or two when it wraps.
    ///
    /// Splitting at the antimeridian is what lets every longitude comparison above be written as a
    /// plain ordered test.
    private var longitudeSpans: [ClosedRange<Double>] {
        crossesAntimeridian ? [west...180, -180...east] : [west...east]
    }

    private func containsLongitude(_ longitude: Double) -> Bool {
        longitudeSpans.contains { $0.contains(longitude) }
    }
}

// MARK: - GeoJSON representation

extension GeographicBounds: Codable {
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let values = try (0..<(container.count ?? 0)).map { _ in try container.decode(Double.self) }
        switch values.count {
        case 4:
            self.init(west: values[0], south: values[1], east: values[2], north: values[3])
        case 6:
            self.init(
                west: values[0],
                south: values[1],
                east: values[3],
                north: values[4],
                minimumAltitude: values[2],
                maximumAltitude: values[5]
            )
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "A GeoJSON bbox has four values, or six when it carries altitudes"
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        if let minimumAltitude, let maximumAltitude {
            try container.encode(contentsOf: [west, south, minimumAltitude, east, north, maximumAltitude])
        } else {
            try container.encode(contentsOf: [west, south, east, north])
        }
    }
}
