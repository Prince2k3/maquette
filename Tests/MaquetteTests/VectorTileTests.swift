import Foundation
import Testing
import simd
@testable import Maquette

/// Writes the bytes a vector tile is made of.
///
/// Real tiles are the wrong fixture for a decoder: they are hundreds of kilobytes, they cannot be
/// checked into a package that ships no resources, and when a test fails against one there is no way
/// to tell a decoding bug from a surprise in the data. These builders make the input exactly as
/// small as the property under test.
enum MVT {
    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    static func key(_ field: Int, _ wire: UInt8) -> [UInt8] {
        varint(UInt64(field) << 3 | UInt64(wire))
    }

    static func delimited(_ field: Int, _ payload: [UInt8]) -> [UInt8] {
        key(field, 2) + varint(UInt64(payload.count)) + payload
    }

    static func string(_ field: Int, _ text: String) -> [UInt8] {
        delimited(field, Array(text.utf8))
    }

    static func uint(_ field: Int, _ value: UInt64) -> [UInt8] {
        key(field, 0) + varint(value)
    }

    static func packed(_ field: Int, _ values: [UInt32]) -> [UInt8] {
        delimited(field, values.flatMap { varint(UInt64($0)) })
    }

    /// The unpacked spelling of a repeated scalar: one key per value. Legal, and what a decoder
    /// assuming the packed form misreads as a field number.
    static func unpacked(_ field: Int, _ values: [UInt32]) -> [UInt8] {
        values.flatMap { uint(field, UInt64($0)) }
    }

    static func zigzag(_ value: Int32) -> UInt32 {
        UInt32(bitPattern: (value << 1) ^ (value >> 31))
    }

    static func command(_ identifier: UInt32, _ count: Int) -> UInt32 {
        identifier | (UInt32(count) << 3)
    }

    static let moveTo: UInt32 = 1
    static let lineTo: UInt32 = 2
    static let closePath: UInt32 = 7

    /// A closed ring, delta-encoded from `cursor`, as the geometry command stream for one ring.
    static func ring(_ points: [SIMD2<Int32>], from cursor: inout SIMD2<Int32>) -> [UInt32] {
        var stream: [UInt32] = [command(moveTo, 1)]
        stream += [zigzag(points[0].x - cursor.x), zigzag(points[0].y - cursor.y)]
        cursor = points[0]

        stream.append(command(lineTo, points.count - 1))
        for point in points.dropFirst() {
            stream += [zigzag(point.x - cursor.x), zigzag(point.y - cursor.y)]
            cursor = point
        }
        stream.append(command(closePath, 1))
        return stream
    }

    static func feature(type: Int, tags: [UInt32] = [], geometry: [UInt32]) -> [UInt8] {
        var body: [UInt8] = []
        if !tags.isEmpty { body += packed(2, tags) }
        body += uint(3, UInt64(type))
        body += packed(4, geometry)
        return delimited(2, body)
    }

    /// Value message bodies, to be wrapped as a layer's field 4.
    static func stringValue(_ text: String) -> [UInt8] { string(1, text) }
    static func doubleValue(_ value: Double) -> [UInt8] {
        key(3, 1) + withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) }
    }
    static func intValue(_ value: Int64) -> [UInt8] { uint(4, UInt64(bitPattern: value)) }
    static func boolValue(_ value: Bool) -> [UInt8] { uint(7, value ? 1 : 0) }

    /// A layer. `tablesFirst: false` writes the key/value tables *after* the features, which the
    /// format allows and which a decoder resolving tags as it reads gets wrong.
    static func layer(
        name: String,
        extent: Int = 4096,
        keys: [String] = [],
        values: [[UInt8]] = [],
        features: [[UInt8]],
        tablesFirst: Bool = true
    ) -> [UInt8] {
        let tables = keys.flatMap { string(3, $0) } + values.flatMap { delimited(4, $0) }
        var body = uint(15, 2) + string(1, name)
        body += tablesFirst ? tables + features.flatMap { $0 } : features.flatMap { $0 } + tables
        body += uint(5, UInt64(extent))
        return delimited(3, body)
    }

    static func tile(_ layers: [[UInt8]]) -> Data {
        Data(layers.flatMap { $0 })
    }

    /// A square wound the way an exterior ring is: positive shoelace area in a y-down grid.
    static func square(x: Int32, y: Int32, side: Int32) -> [SIMD2<Int32>] {
        [SIMD2(x, y), SIMD2(x + side, y), SIMD2(x + side, y + side), SIMD2(x, y + side)]
    }
}

@Suite("Protobuf wire format")
struct ProtobufReaderTests {
    @Test func readsVarintsAcrossByteBoundaries() throws {
        var reader = ProtobufReader(Data(MVT.varint(1) + MVT.varint(300) + MVT.varint(UInt64.max)))
        #expect(try reader.varint() == 1)
        #expect(try reader.varint() == 300)
        #expect(try reader.varint() == UInt64.max)
        #expect(!reader.hasMore)
    }

    @Test func refusesAVarintThatNeverEnds() {
        // Eleven continuation bytes: more groups than a 64-bit value can hold. Left unchecked this
        // runs to the end of the buffer instead of failing.
        let runaway = Data([UInt8](repeating: 0x80, count: 11) + [0x01])
        var reader = ProtobufReader(runaway)
        #expect(throws: ProtobufError.malformedVarint) { _ = try reader.varint() }
    }

    @Test func refusesAValueThatRunsPastTheEnd() {
        var reader = ProtobufReader(Data(MVT.key(1, 2) + MVT.varint(50) + [1, 2, 3]))
        #expect(throws: ProtobufError.truncated) {
            _ = try reader.nextField()
            _ = try reader.message()
        }
    }

    @Test func refusesGroupWireTypes() {
        var reader = ProtobufReader(Data(MVT.key(1, 3)))
        #expect(throws: ProtobufError.unsupportedWireType(3)) { _ = try reader.nextField() }
    }

    @Test func stepsOverFieldsItDoesNotWant() throws {
        // A field of every wire type ahead of the one being looked for.
        let bytes = MVT.uint(1, 99)
            + MVT.key(2, 1) + [UInt8](repeating: 7, count: 8)
            + MVT.key(3, 5) + [1, 2, 3, 4]
            + MVT.string(4, "skipped")
            + MVT.string(9, "wanted")
        var reader = ProtobufReader(Data(bytes))
        var found: String?
        while let field = try reader.nextField() {
            if field.number == 9 {
                found = try reader.string()
            } else {
                try reader.skip(field.wire)
            }
        }
        #expect(found == "wanted")
    }

    @Test func undoesZigzagEncoding() {
        #expect(ProtobufReader.zigzag(0) == 0)
        #expect(ProtobufReader.zigzag(1) == -1)
        #expect(ProtobufReader.zigzag(2) == 1)
        #expect(ProtobufReader.zigzag(3) == -2)
        for value: Int32 in [-32_768, -1, 0, 1, 4095, 65_536] {
            #expect(ProtobufReader.zigzag(MVT.zigzag(value)) == value)
        }
    }
}

@Suite("Vector tile decoding")
struct VectorTileTests {
    /// One polygon feature, built from rings sharing a single cursor as a real encoder writes them.
    private func polygonTile(
        _ rings: [[SIMD2<Int32>]],
        extent: Int = 4096,
        keys: [String] = [],
        values: [[UInt8]] = [],
        tags: [UInt32] = [],
        tablesFirst: Bool = true
    ) throws -> VectorTile {
        var cursor = SIMD2<Int32>(0, 0)
        let geometry = rings.flatMap { MVT.ring($0, from: &cursor) }
        return try VectorTile(
            data: MVT.tile([
                MVT.layer(
                    name: "building",
                    extent: extent,
                    keys: keys,
                    values: values,
                    features: [MVT.feature(type: 3, tags: tags, geometry: geometry)],
                    tablesFirst: tablesFirst
                )
            ])
        )
    }

    @Test func decodesARingFromDeltaEncodedGeometry() throws {
        let tile = try polygonTile([MVT.square(x: 5, y: 7, side: 10)])
        let layer = try #require(tile.layer(named: "building"))
        #expect(layer.extent == 4096)

        let feature = try #require(layer.features.first)
        #expect(feature.geometryType == .polygon)
        let ring = try #require(feature.rings.first)
        #expect(ring.points == [SIMD2(5, 7), SIMD2(15, 7), SIMD2(15, 17), SIMD2(5, 17)])
    }

    @Test func doesNotRepeatTheFirstPointOnClosePath() throws {
        let tile = try polygonTile([MVT.square(x: 0, y: 0, side: 4)])
        let ring = try #require(tile.layer(named: "building")?.features.first?.rings.first)
        // Four corners, not five: ClosePath implies the return rather than encoding it, and a
        // repeated point puts a zero-length wall in every extrusion.
        #expect(ring.points.count == 4)
        #expect(ring.points.first != ring.points.last)
    }

    @Test func keepsTheCursorAcrossRingsWithinAFeature() throws {
        let outer = MVT.square(x: 0, y: 0, side: 100)
        let inner = MVT.square(x: 900, y: 900, side: 10)
        let tile = try polygonTile([outer, inner])
        let rings = try #require(tile.layer(named: "building")?.features.first?.rings)

        #expect(rings.count == 2)
        // The second ring's first MoveTo is a delta from the *last point of the first ring*. A
        // decoder resetting the cursor per ring puts this one near the tile origin instead.
        #expect(rings[1].points[0] == SIMD2(900, 900))
        #expect(rings[1].points.last == SIMD2(900, 910))
    }

    @Test func classifiesRingsByWinding() throws {
        let outer = MVT.square(x: 0, y: 0, side: 100)
        // Same square, wound the other way: a hole rather than a second building.
        let hole = Array(MVT.square(x: 20, y: 20, side: 30).reversed())
        let tile = try polygonTile([outer, hole])
        let rings = try #require(tile.layer(named: "building")?.features.first?.rings)

        #expect(rings[0].isExterior)
        #expect(!rings[1].isExterior)
        #expect(rings[0].doubledSignedArea == 20_000)
        #expect(rings[1].doubledSignedArea == -1_800)
    }

    @Test func keepsCoordinatesOutsideTheExtentGrid() throws {
        // Encoders buffer geometry past the tile edge; a decoder clamping to `0..<extent` would
        // shear every building that straddles a seam flat against it.
        let tile = try polygonTile([[SIMD2(-8, -8), SIMD2(4104, -8), SIMD2(4104, 4104), SIMD2(-8, 4104)]])
        let ring = try #require(tile.layer(named: "building")?.features.first?.rings.first)
        #expect(ring.points.map(\.x).min() == -8)
        #expect(ring.points.map(\.x).max() == 4104)
    }

    @Test func resolvesAttributesWhenTheTableFollowsTheFeatures() throws {
        for tablesFirst in [true, false] {
            let tile = try polygonTile(
                [MVT.square(x: 0, y: 0, side: 10)],
                keys: ["render_height", "hide_3d", "name"],
                values: [MVT.doubleValue(42.5), MVT.boolValue(true), MVT.stringValue("Tower")],
                tags: [0, 0, 1, 1, 2, 2],
                tablesFirst: tablesFirst
            )
            let feature = try #require(tile.layer(named: "building")?.features.first)
            #expect(feature.attributes["render_height"] == .number(42.5))
            #expect(feature.attributes["hide_3d"] == .boolean(true))
            #expect(feature.attributes["name"] == .string("Tower"))
        }
    }

    @Test func readsEveryScalarValueType() throws {
        let tile = try polygonTile(
            [MVT.square(x: 0, y: 0, side: 10)],
            keys: ["double", "int", "flag", "text"],
            values: [
                MVT.doubleValue(-3.25),
                MVT.intValue(1_234),
                MVT.boolValue(false),
                MVT.stringValue("12.5")
            ],
            tags: [0, 0, 1, 1, 2, 2, 3, 3]
        )
        let attributes = try #require(tile.layer(named: "building")?.features.first?.attributes)
        #expect(attributes["double"]?.number == -3.25)
        #expect(attributes["int"]?.number == 1_234)
        #expect(attributes["flag"]?.boolean == false)
        // A number written as a string still reads as a number: OSM's own height tag is one.
        #expect(attributes["text"]?.number == 12.5)
    }

    @Test func acceptsUnpackedRepeatedFields() throws {
        var cursor = SIMD2<Int32>(0, 0)
        let geometry = MVT.ring(MVT.square(x: 1, y: 2, side: 8), from: &cursor)
        var body: [UInt8] = []
        body += MVT.unpacked(2, [0, 0])
        body += MVT.uint(3, 3)
        body += MVT.unpacked(4, geometry)

        let tile = try VectorTile(
            data: MVT.tile([
                MVT.layer(
                    name: "building",
                    keys: ["render_height"],
                    values: [MVT.doubleValue(9)],
                    features: [MVT.delimited(2, body)]
                )
            ])
        )
        let feature = try #require(tile.layer(named: "building")?.features.first)
        #expect(feature.rings.first?.points == [SIMD2(1, 2), SIMD2(9, 2), SIMD2(9, 10), SIMD2(1, 10)])
        #expect(feature.attributes["render_height"] == .number(9))
    }

    @Test func readsOneLayerOutOfSeveral() throws {
        var cursor = SIMD2<Int32>(0, 0)
        let geometry = MVT.ring(MVT.square(x: 0, y: 0, side: 4), from: &cursor)
        let tile = try VectorTile(
            data: MVT.tile([
                MVT.layer(name: "water", features: [MVT.feature(type: 3, geometry: geometry)]),
                MVT.layer(name: "building", extent: 2048,
                          features: [MVT.feature(type: 3, geometry: geometry)]),
                MVT.layer(name: "poi", features: [MVT.feature(type: 1, geometry: geometry)])
            ])
        )
        #expect(tile.layers.count == 3)
        #expect(tile.layer(named: "building")?.extent == 2048)
        #expect(tile.layer(named: "nothing") == nil)
    }

    @Test func saysSoWhenTheTileArrivesCompressed() {
        #expect(throws: DioramaError.self) {
            _ = try VectorTile(data: Data([0x1F, 0x8B, 0x08, 0x00, 0x00]))
        }
    }
}

@Suite("MapTiler buildings")
struct MapTilerBuildingProviderTests {
    private let zoom = MapTilerBuildingProvider.zoom
    /// A z14 tile over downtown San Francisco.
    private let tileX = 2621
    private let tileY = 6333

    private func layer(
        rings: [[SIMD2<Int32>]],
        keys: [String] = [],
        values: [[UInt8]] = [],
        tags: [UInt32] = []
    ) throws -> VectorTileLayer {
        var cursor = SIMD2<Int32>(0, 0)
        let geometry = rings.flatMap { MVT.ring($0, from: &cursor) }
        let tile = try VectorTile(
            data: MVT.tile([
                MVT.layer(
                    name: "building",
                    keys: keys,
                    values: values,
                    features: [MVT.feature(type: 3, tags: tags, geometry: geometry)]
                )
            ])
        )
        return try #require(tile.layer(named: "building"))
    }

    @Test func placesTheGridOnTheGround() throws {
        // A ring on the tile's own corners must come back as the tile's own bounds.
        let corners: [SIMD2<Int32>] = [
            SIMD2(0, 0), SIMD2(4096, 0), SIMD2(4096, 4096), SIMD2(0, 4096)
        ]
        let provider = MapTilerBuildingProvider(apiKey: "test")
        let footprints = provider.footprints(
            from: try layer(rings: [corners]), tileX: tileX, tileY: tileY, zoom: zoom
        )
        let outline = try #require(footprints.first?.outline)
        let bounds = TileMath.tileBounds(x: tileX, y: tileY, zoom: zoom)

        #expect(abs(outline.map(\.longitude).min()! - bounds.minLongitude) < 1e-9)
        #expect(abs(outline.map(\.longitude).max()! - bounds.maxLongitude) < 1e-9)
        #expect(abs(outline.map(\.latitude).min()! - bounds.minLatitude) < 1e-9)
        #expect(abs(outline.map(\.latitude).max()! - bounds.maxLatitude) < 1e-9)
    }

    @Test func readsRenderHeightAndFallsBackWhenItIsAbsent() throws {
        let provider = MapTilerBuildingProvider(apiKey: "test", defaultHeightMeters: 8)
        let tall = provider.footprints(
            from: try layer(
                rings: [MVT.square(x: 100, y: 100, side: 50)],
                keys: ["render_height"], values: [MVT.doubleValue(97.5)], tags: [0, 0]
            ),
            tileX: tileX, tileY: tileY, zoom: zoom
        )
        #expect(tall.first?.heightMeters == 97.5)

        let untagged = provider.footprints(
            from: try layer(rings: [MVT.square(x: 100, y: 100, side: 50)]),
            tileX: tileX, tileY: tileY, zoom: zoom
        )
        #expect(untagged.first?.heightMeters == 8)
    }

    @Test func skipsFootprintsMarkedHiddenInThreeDimensions() throws {
        let provider = MapTilerBuildingProvider(apiKey: "test")
        let footprints = provider.footprints(
            from: try layer(
                rings: [MVT.square(x: 100, y: 100, side: 50)],
                keys: ["hide_3d"], values: [MVT.boolValue(true)], tags: [0, 0]
            ),
            tileX: tileX, tileY: tileY, zoom: zoom
        )
        #expect(footprints.isEmpty)
    }

    @Test func dropsCourtyardsRatherThanStandingBuildingsInThem() throws {
        let outer = MVT.square(x: 100, y: 100, side: 200)
        let hole = Array(MVT.square(x: 150, y: 150, side: 50).reversed())
        let provider = MapTilerBuildingProvider(apiKey: "test")
        let footprints = provider.footprints(
            from: try layer(rings: [outer, hole]), tileX: tileX, tileY: tileY, zoom: zoom
        )
        // One block, not a block with a smaller block inside it.
        #expect(footprints.count == 1)
        #expect(footprints[0].outline.count == 4)
    }

    @Test func dropsSeamRepeatsButKeepsSeamPartials() async throws {
        // A bounding box spanning two tiles side by side.
        let left = TileMath.tileBounds(x: tileX, y: tileY, zoom: zoom)
        let right = TileMath.tileBounds(x: tileX + 1, y: tileY, zoom: zoom)
        let inset = (left.maxLatitude - left.minLatitude) * 0.01

        // Whole building inside both tiles' buffer margins: the same ground, encoded twice.
        let repeatedLeft = MVT.square(x: 4000, y: 100, side: 20)
        let repeatedRight = MVT.square(x: 4000 - 4096, y: 100, side: 20)
        // Building crossing the seam: each tile holds a different part of it.
        let partialLeft = [SIMD2<Int32>(4090, 200), SIMD2(4104, 200), SIMD2(4104, 220), SIMD2(4090, 220)]
        let partialRight = [SIMD2<Int32>(-6, 200), SIMD2(14, 200), SIMD2(14, 220), SIMD2(-6, 220)]

        func tileBytes(_ rings: [[SIMD2<Int32>]]) -> Data {
            let features = rings.map { ring -> [UInt8] in
                var cursor = SIMD2<Int32>(0, 0)
                return MVT.feature(type: 3, geometry: MVT.ring(ring, from: &cursor))
            }
            return MVT.tile([MVT.layer(name: "building", features: features)])
        }

        let client = MockHTTPClient(responses: [
            "https://api.maptiler.com/tiles/v3/\(zoom)/\(tileX)/\(tileY).pbf?key=test":
                .init(data: tileBytes([repeatedLeft, partialLeft])),
            "https://api.maptiler.com/tiles/v3/\(zoom)/\(tileX + 1)/\(tileY).pbf?key=test":
                .init(data: tileBytes([repeatedRight, partialRight]))
        ])
        let provider = MapTilerBuildingProvider(apiKey: "test", httpClient: client)

        let footprints = try await provider.fetchBuildings(
            south: left.minLatitude + inset,
            west: left.minLongitude + inset,
            north: left.maxLatitude - inset,
            east: right.maxLongitude - inset
        )

        // The repeat collapses to one; the two partials are different geometry and both survive,
        // because together they are the building and dropping either leaves half of it.
        #expect(footprints.count == 3)
    }

    @Test func treatsAMissingTileAsEmptyGround() async throws {
        // Nothing registered, so the mock answers 404 — which is how a sparse tile pyramid says
        // "no buildings here", not how it reports a failure.
        let provider = MapTilerBuildingProvider(apiKey: "test", httpClient: MockHTTPClient())
        let bounds = TileMath.tileBounds(x: tileX, y: tileY, zoom: zoom)
        let footprints = try await provider.fetchBuildings(
            south: bounds.minLatitude + 0.001,
            west: bounds.minLongitude + 0.001,
            north: bounds.maxLatitude - 0.001,
            east: bounds.maxLongitude - 0.001
        )
        #expect(footprints.isEmpty)
    }

    @Test func raisesARejectedKey() async {
        let client = MockHTTPClient(responses: [
            "https://api.maptiler.com/tiles/v3": .init(statusCode: 403)
        ])
        let provider = MapTilerBuildingProvider(apiKey: "wrong", httpClient: client)
        let bounds = TileMath.tileBounds(x: tileX, y: tileY, zoom: zoom)
        await #expect(throws: DioramaError.self) {
            _ = try await provider.fetchBuildings(
                south: bounds.minLatitude + 0.001,
                west: bounds.minLongitude + 0.001,
                north: bounds.maxLatitude - 0.001,
                east: bounds.maxLongitude - 0.001
            )
        }
    }

    @Test func refusesABoundingBoxItWouldFloodTheServiceFor() async {
        let provider = MapTilerBuildingProvider(apiKey: "test", httpClient: MockHTTPClient())
        await #expect(throws: DioramaError.self) {
            _ = try await provider.fetchBuildings(south: 30, west: -125, north: 45, east: -110)
        }
    }

    @Test func buildsTheProviderTheSourceNames() {
        #expect(BuildingSource.openStreetMap.makeProvider(style: .standard) is OSMBuildingProvider)
        let mapTiler = BuildingSource.mapTiler(apiKey: "abc").makeProvider(style: .standard)
        #expect((mapTiler as? MapTilerBuildingProvider)?.apiKey == "abc")
    }
}
