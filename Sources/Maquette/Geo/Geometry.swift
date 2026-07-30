import Foundation

/// The seven GeoJSON geometry types (RFC 7946 §3.1).
///
/// Everything the library draws on a chunk — a pin, a route, an outline, a region to shade — is one
/// of these plus a style. Keeping the geometry a standard, decodable value rather than a bespoke
/// marker-shaped struct is what lets real data be handed in unmodified.
///
/// `bbox` is not carried on a geometry. RFC 7946 §5 permits it on any object, but on a geometry it
/// is a cache of the coordinates that are right there — `Turf.boundingBox(of:)`
/// computes it exactly — so it is read past when decoding and never written. It *is* carried on
/// ``Feature`` and ``FeatureCollection``, where it can describe something the object does not
/// otherwise state.
public enum Geometry: Sendable, Hashable {
    case point(Point)
    case multiPoint(MultiPoint)
    case lineString(LineString)
    case multiLineString(MultiLineString)
    case polygon(Polygon)
    case multiPolygon(MultiPolygon)
    case geometryCollection([Geometry])
}

// MARK: - Point

/// A single position.
public struct Point: Sendable, Hashable {
    public var coordinate: Coordinate

    public init(_ coordinate: Coordinate) {
        self.coordinate = coordinate
    }
}

/// An unordered set of positions.
public struct MultiPoint: Sendable, Hashable {
    public var coordinates: [Coordinate]

    public init(_ coordinates: [Coordinate]) {
        self.coordinates = coordinates
    }
}

// MARK: - Lines

/// A connected run of two or more positions.
public struct LineString: Sendable, Hashable {
    public var coordinates: [Coordinate]

    public init(_ coordinates: [Coordinate]) {
        self.coordinates = coordinates
    }

    /// Whether the line meets RFC 7946's requirement of at least two positions.
    public var isValid: Bool {
        coordinates.count >= 2
    }
}

/// A set of lines.
public struct MultiLineString: Sendable, Hashable {
    public var lineStrings: [LineString]

    public init(_ lineStrings: [LineString]) {
        self.lineStrings = lineStrings
    }

    public init(coordinates: [[Coordinate]]) {
        self.lineStrings = coordinates.map(LineString.init)
    }
}

// MARK: - Rings and polygons

/// A closed run of positions bounding an area.
///
/// The ring closes itself: RFC 7946 §3.1.6 requires the first and last positions to be identical,
/// and callers building a ring by hand routinely forget, so ``init(_:)`` appends the first position
/// when it has to. Everything downstream — area, containment, the diorama boundary — may then
/// assume closure rather than testing for it.
///
/// Winding is *not* normalized. The RFC asks that exterior rings run counterclockwise and holes
/// clockwise, but also that parsers not reject rings that do not, and real data is full of both.
/// Nothing in this library depends on a ring's winding; ``isClockwise`` is there for the cases that
/// want to know.
public struct LinearRing: Sendable, Hashable {
    public private(set) var coordinates: [Coordinate]

    public init(_ coordinates: [Coordinate]) {
        var closed = coordinates
        if let first = closed.first, let last = closed.last,
           first.longitude != last.longitude || first.latitude != last.latitude {
            closed.append(first)
        }
        self.coordinates = closed
    }

    /// Whether the ring meets RFC 7946's requirement of four or more positions once closed.
    public var isValid: Bool {
        coordinates.count >= 4
    }

    /// The ring's positions without the repeated closing one.
    public var open: [Coordinate] {
        coordinates.count >= 2 ? Array(coordinates.dropLast()) : coordinates
    }

    /// Whether the ring winds clockwise in longitude/latitude space.
    ///
    /// Measured by the shoelace sum, which is a planar test applied to degrees — good enough to
    /// name a winding, and deliberately not used as an area. Real area lives in ``Turf``, which
    /// measures on the sphere.
    public var isClockwise: Bool {
        var sum = 0.0
        for index in coordinates.indices.dropLast() {
            let a = coordinates[index]
            let b = coordinates[index + 1]
            sum += (b.longitude - a.longitude) * (b.latitude + a.latitude)
        }
        return sum > 0
    }

    /// The same ring wound the other way.
    public var reversed: LinearRing {
        LinearRing(coordinates.reversed())
    }
}

/// An area bounded by an exterior ring, with any number of holes.
public struct Polygon: Sendable, Hashable {
    /// The exterior ring first, then the holes.
    public var rings: [LinearRing]

    public init(rings: [LinearRing]) {
        self.rings = rings
    }

    public init(exterior: LinearRing, holes: [LinearRing] = []) {
        self.rings = [exterior] + holes
    }

    public init(_ coordinates: [Coordinate]) {
        self.rings = [LinearRing(coordinates)]
    }

    public var exterior: LinearRing? {
        rings.first
    }

    public var holes: ArraySlice<LinearRing> {
        rings.dropFirst()
    }
}

/// A set of polygons.
public struct MultiPolygon: Sendable, Hashable {
    public var polygons: [Polygon]

    public init(_ polygons: [Polygon]) {
        self.polygons = polygons
    }
}

// MARK: - Positions

extension Geometry {
    /// Every position in the geometry, in document order.
    ///
    /// Structure is deliberately flattened away: this answers "where is this thing" for bounds and
    /// projection, not "what shape is it".
    public var coordinates: [Coordinate] {
        switch self {
        case .point(let point):
            return [point.coordinate]
        case .multiPoint(let multiPoint):
            return multiPoint.coordinates
        case .lineString(let line):
            return line.coordinates
        case .multiLineString(let lines):
            return lines.lineStrings.flatMap(\.coordinates)
        case .polygon(let polygon):
            return polygon.rings.flatMap(\.coordinates)
        case .multiPolygon(let multiPolygon):
            return multiPolygon.polygons.flatMap { $0.rings.flatMap(\.coordinates) }
        case .geometryCollection(let geometries):
            return geometries.flatMap(\.coordinates)
        }
    }
}

// MARK: - Codable

/// The members a GeoJSON geometry object may carry.
private enum GeometryKeys: String, CodingKey {
    case type
    case coordinates
    case geometries
}

private func decodeType(
    _ container: KeyedDecodingContainer<GeometryKeys>,
    expecting expected: String
) throws {
    let found = try container.decode(String.self, forKey: .type)
    guard found == expected else {
        throw DecodingError.dataCorruptedError(
            forKey: .type,
            in: container,
            debugDescription: "Expected a \(expected) and found a \(found)"
        )
    }
}

private func encodeType(_ type: String, into encoder: any Encoder) throws -> KeyedEncodingContainer<GeometryKeys> {
    var container = encoder.container(keyedBy: GeometryKeys.self)
    try container.encode(type, forKey: .type)
    return container
}

extension Point: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: GeometryKeys.self)
        try decodeType(container, expecting: "Point")
        coordinate = try container.decode(Coordinate.self, forKey: .coordinates)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = try encodeType("Point", into: encoder)
        try container.encode(coordinate, forKey: .coordinates)
    }
}

extension MultiPoint: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: GeometryKeys.self)
        try decodeType(container, expecting: "MultiPoint")
        coordinates = try container.decode([Coordinate].self, forKey: .coordinates)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = try encodeType("MultiPoint", into: encoder)
        try container.encode(coordinates, forKey: .coordinates)
    }
}

extension LineString: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: GeometryKeys.self)
        try decodeType(container, expecting: "LineString")
        self.init(try container.decode([Coordinate].self, forKey: .coordinates))
        guard isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .coordinates,
                in: container,
                debugDescription: "A LineString needs at least two positions"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = try encodeType("LineString", into: encoder)
        try container.encode(coordinates, forKey: .coordinates)
    }
}

extension MultiLineString: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: GeometryKeys.self)
        try decodeType(container, expecting: "MultiLineString")
        self.init(coordinates: try container.decode([[Coordinate]].self, forKey: .coordinates))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = try encodeType("MultiLineString", into: encoder)
        try container.encode(lineStrings.map(\.coordinates), forKey: .coordinates)
    }
}

extension Polygon: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: GeometryKeys.self)
        try decodeType(container, expecting: "Polygon")
        let rings = try container.decode([[Coordinate]].self, forKey: .coordinates).map(LinearRing.init)
        guard rings.allSatisfy(\.isValid) else {
            throw DecodingError.dataCorruptedError(
                forKey: .coordinates,
                in: container,
                debugDescription: "A polygon ring needs at least four positions once closed"
            )
        }
        self.init(rings: rings)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = try encodeType("Polygon", into: encoder)
        try container.encode(rings.map(\.coordinates), forKey: .coordinates)
    }
}

extension MultiPolygon: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: GeometryKeys.self)
        try decodeType(container, expecting: "MultiPolygon")
        let polygons = try container.decode([[[Coordinate]]].self, forKey: .coordinates).map {
            Polygon(rings: $0.map(LinearRing.init))
        }
        guard polygons.allSatisfy({ $0.rings.allSatisfy(\.isValid) }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .coordinates,
                in: container,
                debugDescription: "A polygon ring needs at least four positions once closed"
            )
        }
        self.init(polygons)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = try encodeType("MultiPolygon", into: encoder)
        try container.encode(polygons.map { $0.rings.map(\.coordinates) }, forKey: .coordinates)
    }
}

extension Geometry: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: GeometryKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "Point":
            self = .point(try Point(from: decoder))
        case "MultiPoint":
            self = .multiPoint(try MultiPoint(from: decoder))
        case "LineString":
            self = .lineString(try LineString(from: decoder))
        case "MultiLineString":
            self = .multiLineString(try MultiLineString(from: decoder))
        case "Polygon":
            self = .polygon(try Polygon(from: decoder))
        case "MultiPolygon":
            self = .multiPolygon(try MultiPolygon(from: decoder))
        case "GeometryCollection":
            self = .geometryCollection(try container.decode([Geometry].self, forKey: .geometries))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "\(type) is not a GeoJSON geometry"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .point(let value): try value.encode(to: encoder)
        case .multiPoint(let value): try value.encode(to: encoder)
        case .lineString(let value): try value.encode(to: encoder)
        case .multiLineString(let value): try value.encode(to: encoder)
        case .polygon(let value): try value.encode(to: encoder)
        case .multiPolygon(let value): try value.encode(to: encoder)
        case .geometryCollection(let geometries):
            var container = try encodeType("GeometryCollection", into: encoder)
            try container.encode(geometries, forKey: .geometries)
        }
    }
}
