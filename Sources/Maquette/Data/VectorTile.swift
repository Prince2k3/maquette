import Foundation
import simd

/// What a feature's geometry describes.
enum VectorTileGeometryType: Int, Sendable {
    case unknown = 0
    case point = 1
    case lineString = 2
    case polygon = 3
}

/// An attribute value. Vector tiles allow seven scalar types; three are enough to read them, since
/// every numeric type answers the same question and no consumer here cares how wide it was on the
/// wire.
enum VectorTileValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case boolean(Bool)

    /// The value as a number, if it is one. A source that writes `"12"` where it means 12 is common
    /// enough — OSM's own `height` tag is a string — that the string case is parsed rather than
    /// refused.
    var number: Double? {
        switch self {
        case .number(let value): return value
        case .string(let text): return Double(text)
        case .boolean(let flag): return flag ? 1 : 0
        }
    }

    var boolean: Bool {
        switch self {
        case .boolean(let flag): return flag
        case .number(let value): return value != 0
        case .string(let text): return text == "true" || text == "1"
        }
    }
}

/// One closed or open run of points in a feature, in the layer's tile-local integer grid.
struct VectorTileRing: Sendable {
    /// The points, **without** a repeated closing point: `ClosePath` implies the return to the
    /// start rather than encoding it, and the rest of this package treats an outline as implicitly
    /// closed.
    let points: [SIMD2<Int32>]
    /// Twice the shoelace area, kept exact in `Int64` because the sign is what classifies the ring
    /// and a large ring can overflow 32 bits before the halving.
    let doubledSignedArea: Int64

    /// Whether this ring bounds solid ground rather than a hole in it.
    ///
    /// Winding is the only thing that says so. The spec fixes it: in tile coordinates, which run
    /// with y *downwards*, an exterior ring has positive area and an interior ring negative. There
    /// is no other marker — a polygon feature is a flat list of rings, and a building with a
    /// courtyard is two of them, so reading the sign wrong turns every courtyard into a second
    /// building sitting inside the first.
    var isExterior: Bool { doubledSignedArea > 0 }
}

/// One feature: a geometry and the attributes attached to it.
struct VectorTileFeature: Sendable {
    let geometryType: VectorTileGeometryType
    let rings: [VectorTileRing]
    let attributes: [String: VectorTileValue]
}

/// One named layer of a tile.
struct VectorTileLayer: Sendable {
    let name: String
    /// The width of this layer's coordinate grid. 4096 in practice, but it is per-layer and
    /// declared, so it is read rather than assumed.
    let extent: Int
    let features: [VectorTileFeature]
}

/// Decodes a Mapbox Vector Tile.
///
/// The format is protobuf carrying integer geometry in a tile-local grid, and it is compact because
/// of three encodings that all have to be undone in the right order. Each is easy to get subtly
/// wrong in a way that still produces plausible-looking polygons.
///
/// ## Geometry is a command stream, and the cursor spans rings
///
/// Points arrive as deltas from a cursor, and **the cursor carries across rings within a feature**.
/// A building with a courtyard is one feature of two rings, and the second ring's first `MoveTo` is
/// a delta from the last point of the first ring — not from the tile origin. Resetting the cursor
/// per ring collapses every ring after the first onto the corner of the tile, which looks like a
/// scattering of degenerate slivers at (0, 0) rather than like a decoding bug.
///
/// `ClosePath` carries no parameters and implies the return to the ring's first point, so that
/// point must not be appended. Appending it puts a zero-length edge in every extruded wall.
///
/// ## Coordinates run outside the grid
///
/// Measured on a real z14 tile of San Francisco, x and y ranged **-8 to 4104 against an extent of
/// 4096**: encoders buffer geometry a little past the tile edge so that a renderer drawing one tile
/// has enough context to avoid a seam. Two consequences for anything reading these as data rather
/// than drawing them. A feature straddling a tile edge appears in **both** tiles, each time as a
/// partial — so the two partials together are the shape and dropping either leaves half of it. And
/// a feature lying entirely inside the buffer appears **complete** in both, which is a true
/// duplicate and the only thing worth de-duplicating.
///
/// ## Attributes are a table, and the table can arrive last
///
/// A feature's `tags` are indices, alternating into the layer's `keys` and `values` arrays. Nothing
/// in the format requires those arrays to precede the features that index them, so tags are held
/// raw while the layer is scanned and resolved only once it is complete. Resolving them as each
/// feature is read works against every encoder that writes the tables first and returns empty
/// attributes against one that does not.
struct VectorTile: Sendable {
    let layers: [VectorTileLayer]

    /// The layer with this name, if the tile carries one. Layer names are a schema's business —
    /// `building` in OpenMapTiles — so this is how a caller gets at what it came for.
    func layer(named name: String) -> VectorTileLayer? {
        layers.first { $0.name == name }
    }

    init(data: Data) throws {
        // Not a gzip stream. Tile servers negotiate `Content-Encoding` and URLSession unwraps it,
        // so this only shows up when bytes came from somewhere else — and Foundation exposes no
        // public inflate, so guessing would fail deep inside the varint reader with a message about
        // a malformed tile rather than about compression.
        if data.count >= 2, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B {
            throw DioramaError.unsupportedTileFormat(
                reason: "the vector tile arrived gzip-compressed and was not decompressed in transit"
            )
        }

        var reader = ProtobufReader(data)
        var layers: [VectorTileLayer] = []
        while let field = try reader.nextField() {
            switch field.number {
            case 3 where field.wire == .lengthDelimited:
                layers.append(try VectorTile.decodeLayer(try reader.message()))
            default:
                try reader.skip(field.wire)
            }
        }
        self.layers = layers
    }

    // MARK: - Layer

    private static func decodeLayer(_ reader: ProtobufReader) throws -> VectorTileLayer {
        var reader = reader
        var name = ""
        var extent = 4096
        var keys: [String] = []
        var values: [VectorTileValue] = []
        /// Features with their tag indices unresolved — see the note on the table arriving last.
        var pending: [(type: VectorTileGeometryType, rings: [VectorTileRing], tags: [UInt32])] = []

        while let field = try reader.nextField() {
            switch (field.number, field.wire) {
            case (1, .lengthDelimited):
                name = try reader.string()
            case (2, .lengthDelimited):
                pending.append(try decodeFeature(try reader.message()))
            case (3, .lengthDelimited):
                keys.append(try reader.string())
            case (4, .lengthDelimited):
                values.append(try decodeValue(try reader.message()))
            case (5, .varint):
                extent = Int(try reader.varint())
            default:
                try reader.skip(field.wire)
            }
        }

        let features = pending.map { feature in
            VectorTileFeature(
                geometryType: feature.type,
                rings: feature.rings,
                attributes: resolve(tags: feature.tags, keys: keys, values: values)
            )
        }
        return VectorTileLayer(name: name, extent: max(1, extent), features: features)
    }

    /// Pairs a feature's tag indices off against the layer's tables, skipping any pair that points
    /// outside them rather than trapping — a truncated table should cost the attribute, not the tile.
    private static func resolve(
        tags: [UInt32],
        keys: [String],
        values: [VectorTileValue]
    ) -> [String: VectorTileValue] {
        guard !tags.isEmpty else { return [:] }
        var attributes: [String: VectorTileValue] = [:]
        attributes.reserveCapacity(tags.count / 2)
        var index = 0
        while index + 1 < tags.count {
            let key = Int(tags[index])
            let value = Int(tags[index + 1])
            index += 2
            guard key < keys.count, value < values.count else { continue }
            attributes[keys[key]] = values[value]
        }
        return attributes
    }

    // MARK: - Feature

    private static func decodeFeature(
        _ reader: ProtobufReader
    ) throws -> (type: VectorTileGeometryType, rings: [VectorTileRing], tags: [UInt32]) {
        var reader = reader
        var type = VectorTileGeometryType.unknown
        var tags: [UInt32] = []
        var geometry: [UInt32] = []

        while let field = try reader.nextField() {
            switch (field.number, field.wire) {
            case (2, _):
                try reader.repeatedVarint(into: &tags, wire: field.wire)
            case (3, .varint):
                type = VectorTileGeometryType(rawValue: Int(try reader.varint())) ?? .unknown
            case (4, _):
                try reader.repeatedVarint(into: &geometry, wire: field.wire)
            default:
                try reader.skip(field.wire)
            }
        }

        return (type, decodeGeometry(geometry, type: type), tags)
    }

    // MARK: - Geometry

    private static let moveTo: UInt32 = 1
    private static let lineTo: UInt32 = 2
    private static let closePath: UInt32 = 7

    /// Walks the command stream into rings.
    ///
    /// Malformed input truncates rather than throws: a command promising more parameters than the
    /// stream holds ends the geometry, keeping whatever was decoded. One bad feature in a tile of
    /// thousands should not cost the tile.
    private static func decodeGeometry(
        _ geometry: [UInt32],
        type: VectorTileGeometryType
    ) -> [VectorTileRing] {
        var rings: [VectorTileRing] = []
        var current: [SIMD2<Int32>] = []
        var cursor = SIMD2<Int32>(0, 0)
        var index = 0

        loop: while index < geometry.count {
            let command = geometry[index]
            index += 1
            let identifier = command & 0x7
            let count = Int(command >> 3)

            switch identifier {
            case moveTo, lineTo:
                for _ in 0..<count {
                    guard index + 1 < geometry.count else { break loop }
                    cursor.x &+= ProtobufReader.zigzag(geometry[index])
                    cursor.y &+= ProtobufReader.zigzag(geometry[index + 1])
                    index += 2
                    // A `MoveTo` opens a new ring — except for points, where a multipoint is a
                    // single `MoveTo` with a count and the whole set belongs together.
                    if identifier == moveTo, type != .point, !current.isEmpty {
                        rings.append(ring(current))
                        current = []
                    }
                    current.append(cursor)
                }
            case closePath:
                // No parameters, and the closing point is implied rather than encoded.
                if !current.isEmpty {
                    rings.append(ring(current))
                    current = []
                }
            default:
                // An unknown command carries an unknown number of parameters, so there is no way to
                // step over it and stay in sync.
                break loop
            }
        }

        if !current.isEmpty { rings.append(ring(current)) }
        return rings
    }

    private static func ring(_ points: [SIMD2<Int32>]) -> VectorTileRing {
        VectorTileRing(points: points, doubledSignedArea: doubledArea(of: points))
    }

    /// Twice the shoelace area of a ring, treated as closed.
    private static func doubledArea(of points: [SIMD2<Int32>]) -> Int64 {
        guard points.count >= 3 else { return 0 }
        var total: Int64 = 0
        var previous = points[points.count - 1]
        for point in points {
            total += Int64(previous.x) * Int64(point.y) - Int64(point.x) * Int64(previous.y)
            previous = point
        }
        return total
    }

    // MARK: - Value

    private static func decodeValue(_ reader: ProtobufReader) throws -> VectorTileValue {
        var reader = reader
        while let field = try reader.nextField() {
            switch (field.number, field.wire) {
            case (1, .lengthDelimited):
                return .string(try reader.string())
            case (2, .fixed32):
                return .number(Double(try reader.float()))
            case (3, .fixed64):
                return .number(try reader.double())
            case (4, .varint):
                return .number(Double(Int64(bitPattern: try reader.varint())))
            case (5, .varint):
                return .number(Double(try reader.varint()))
            case (6, .varint):
                // sint64: zigzagged like the geometry parameters, for the same reason.
                let raw = try reader.varint()
                return .number(Double(Int64(bitPattern: raw >> 1) ^ -Int64(raw & 1)))
            case (7, .varint):
                return .boolean(try reader.varint() != 0)
            default:
                try reader.skip(field.wire)
            }
        }
        return .string("")
    }
}
