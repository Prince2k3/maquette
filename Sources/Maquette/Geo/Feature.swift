import Foundation

/// A geometry with an identity and a bag of properties (RFC 7946 §3.2).
///
/// This is the unit the rest of the library annotates a diorama with: an annotation is a feature
/// plus a style, so the same value that came out of a `.geojson` file is the one that gets drawn.
public struct Feature: Sendable, Hashable {
    /// The feature's identifier, which GeoJSON allows to be either a string or a number.
    public var id: Identifier?
    /// The geometry, which the spec permits to be null.
    public var geometry: Geometry?
    /// The feature's properties, which the spec permits to be null.
    public var properties: [String: JSONValue]?
    /// The extent the document declared, if it declared one. Not maintained as the geometry
    /// changes — `Turf.boundingBox(of:)` measures the geometry itself.
    public var boundingBox: GeographicBounds?

    public init(
        geometry: Geometry?,
        id: Identifier? = nil,
        properties: [String: JSONValue]? = nil,
        boundingBox: GeographicBounds? = nil
    ) {
        self.id = id
        self.geometry = geometry
        self.properties = properties
        self.boundingBox = boundingBox
    }

    /// A GeoJSON feature identifier: a string or a number, per RFC 7946 §3.2.
    public enum Identifier: Sendable, Hashable {
        case string(String)
        case number(Double)
    }

    /// Reads a property.
    public subscript(property key: String) -> JSONValue? {
        get { properties?[key] }
        set { properties?[key] = newValue }
    }
}

// MARK: - Convenience

extension Feature {
    /// A feature holding a single position.
    public static func point(
        _ coordinate: Coordinate,
        id: Identifier? = nil,
        properties: [String: JSONValue]? = nil
    ) -> Feature {
        Feature(geometry: .point(Point(coordinate)), id: id, properties: properties)
    }

    /// A feature holding a run of positions.
    public static func line(
        _ coordinates: [Coordinate],
        id: Identifier? = nil,
        properties: [String: JSONValue]? = nil
    ) -> Feature {
        Feature(geometry: .lineString(LineString(coordinates)), id: id, properties: properties)
    }

    /// A feature holding an area bounded by the given ring.
    public static func area(
        _ coordinates: [Coordinate],
        id: Identifier? = nil,
        properties: [String: JSONValue]? = nil
    ) -> Feature {
        Feature(geometry: .polygon(Polygon(coordinates)), id: id, properties: properties)
    }
}

extension Feature.Identifier: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension Feature.Identifier: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

// MARK: - Feature collection

/// A set of features (RFC 7946 §3.3), which is what a `.geojson` file usually holds.
public struct FeatureCollection: Sendable, Hashable {
    public var features: [Feature]
    /// The extent the document declared, if it declared one.
    public var boundingBox: GeographicBounds?

    public init(_ features: [Feature], boundingBox: GeographicBounds? = nil) {
        self.features = features
        self.boundingBox = boundingBox
    }
}

extension FeatureCollection: RandomAccessCollection {
    public var startIndex: Int { features.startIndex }
    public var endIndex: Int { features.endIndex }
    public subscript(position: Int) -> Feature { features[position] }
}

// MARK: - Any GeoJSON document

/// Whatever a GeoJSON document turned out to hold.
///
/// A file may be a bare geometry, a single feature, or a collection, and which one is not known
/// until it is read — so decoding into a fixed type means guessing, and guessing wrong throws on
/// perfectly valid data. Decode into this and switch.
public enum GeoJSONObject: Sendable, Hashable {
    case geometry(Geometry)
    case feature(Feature)
    case featureCollection(FeatureCollection)

    /// Every feature in the document. A bare geometry reads as one feature with no properties, so
    /// callers that only want features do not have to care which form the file took.
    public var features: [Feature] {
        switch self {
        case .geometry(let geometry): return [Feature(geometry: geometry)]
        case .feature(let feature): return [feature]
        case .featureCollection(let collection): return collection.features
        }
    }
}

// MARK: - Codable

private enum FeatureKeys: String, CodingKey {
    case type
    case id
    case geometry
    case properties
    case features
    case bbox
}

extension Feature.Identifier: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .number(try container.decode(Double.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        }
    }
}

extension Feature: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: FeatureKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == "Feature" else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Expected a Feature and found a \(type)"
            )
        }
        id = try container.decodeIfPresent(Identifier.self, forKey: .id)
        geometry = try container.decodeIfPresent(Geometry.self, forKey: .geometry)
        properties = try container.decodeIfPresent([String: JSONValue].self, forKey: .properties)
        boundingBox = try container.decodeIfPresent(GeographicBounds.self, forKey: .bbox)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: FeatureKeys.self)
        try container.encode("Feature", forKey: .type)
        try container.encodeIfPresent(id, forKey: .id)
        // Both of these are written even when absent: RFC 7946 §3.2 requires the members to be
        // present, with null standing for "unknown".
        try container.encode(geometry, forKey: .geometry)
        try container.encode(properties, forKey: .properties)
        try container.encodeIfPresent(boundingBox, forKey: .bbox)
    }
}

extension FeatureCollection: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: FeatureKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == "FeatureCollection" else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Expected a FeatureCollection and found a \(type)"
            )
        }
        features = try container.decode([Feature].self, forKey: .features)
        boundingBox = try container.decodeIfPresent(GeographicBounds.self, forKey: .bbox)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: FeatureKeys.self)
        try container.encode("FeatureCollection", forKey: .type)
        try container.encode(features, forKey: .features)
        try container.encodeIfPresent(boundingBox, forKey: .bbox)
    }
}

extension GeoJSONObject: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: FeatureKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "Feature":
            self = .feature(try Feature(from: decoder))
        case "FeatureCollection":
            self = .featureCollection(try FeatureCollection(from: decoder))
        default:
            self = .geometry(try Geometry(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .geometry(let value): try value.encode(to: encoder)
        case .feature(let value): try value.encode(to: encoder)
        case .featureCollection(let value): try value.encode(to: encoder)
        }
    }
}
