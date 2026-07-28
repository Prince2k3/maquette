import Foundation
import RealityKit
import Testing
import simd
@testable import Maquette

@Suite("OSM building decoding")
struct OSMBuildingProviderTests {
    private let provider = OSMBuildingProvider()

    /// Overpass closes rings by repeating the first node. Left in, that duplicate becomes a
    /// zero-length wall and a degenerate ear during triangulation.
    @Test func dropsTheRepeatedClosingNode() throws {
        let json = """
        {"elements":[{"type":"way","geometry":[
            {"lat":37.7,"lon":-122.4},
            {"lat":37.7,"lon":-122.3999},
            {"lat":37.7001,"lon":-122.3999},
            {"lat":37.7001,"lon":-122.4},
            {"lat":37.7,"lon":-122.4}],
          "tags":{"building":"yes"}}]}
        """
        let buildings = provider.decode(Data(json.utf8))
        #expect(buildings.count == 1)
        #expect(try #require(buildings.first).outline.count == 4)
    }

    @Test func skipsWaysWithTooFewPoints() {
        let json = """
        {"elements":[
          {"type":"way","geometry":[{"lat":1,"lon":1},{"lat":2,"lon":2}],"tags":{"building":"yes"}},
          {"type":"way","tags":{"building":"yes"}}]}
        """
        #expect(provider.decode(Data(json.utf8)).isEmpty)
    }

    @Test func stopsAtTheMaximum() {
        let way = """
        {"type":"way","geometry":[{"lat":1,"lon":1},{"lat":1,"lon":2},{"lat":2,"lon":2}],\
        "tags":{"building":"yes"}}
        """
        let json = "{\"elements\":[\(Array(repeating: way, count: 5).joined(separator: ","))]}"
        let capped = OSMBuildingProvider(maximumBuildings: 2)
        #expect(capped.decode(Data(json.utf8)).count == 2)
    }

    @Test func readsHeightTagsInPreferenceOrder() {
        #expect(provider.height(from: ["height": "24"]) == 24)
        // `height` wins over levels rather than being averaged with them.
        #expect(provider.height(from: ["height": "24", "building:levels": "2"]) == 24)
        #expect(provider.height(from: ["building:levels": "5"]) == 5 * 3.2)
        #expect(provider.height(from: [:]) == 8)
        #expect(provider.height(from: nil) == 8)
    }

    /// A 40-foot building read as 40 meters is a skyscraper on a residential street, so the unit
    /// suffixes OSM allows are converted rather than ignored.
    @Test func parsesLengthUnits() throws {
        #expect(try #require(OSMBuildingProvider.parseLength("12")) == 12)
        #expect(try #require(OSMBuildingProvider.parseLength("12 m")) == 12)
        #expect(abs(try #require(OSMBuildingProvider.parseLength("40 ft")) - 12.192) < 1e-9)
        #expect(abs(try #require(OSMBuildingProvider.parseLength("40'6\"")) - 12.192) < 1e-9)
        #expect(OSMBuildingProvider.parseLength("tall") == nil)
        #expect(OSMBuildingProvider.parseLength("") == nil)
    }

    @Test func survivesGarbage() {
        #expect(provider.decode(Data("not json".utf8)).isEmpty)
    }

    private static let oneBuilding = """
    {"elements":[{"type":"way","geometry":[
        {"lat":37.7,"lon":-122.4},{"lat":37.7,"lon":-122.3999},{"lat":37.7001,"lon":-122.3999}],
      "tags":{"building":"yes"}}]}
    """

    private static let busy = URL(string: "https://busy.example/api/interpreter")!
    private static let free = URL(string: "https://free.example/api/interpreter")!

    /// A 504 says the instance is loaded, not that the query is wrong, so the next instance is
    /// asked rather than the load being failed.
    @Test func movesToAnotherInstanceWhenOneIsOverloaded() async throws {
        let client = MockHTTPClient(responses: [
            Self.busy.absoluteString: .init(statusCode: 504),
            Self.free.absoluteString: .init(data: Data(Self.oneBuilding.utf8))
        ])
        let provider = OSMBuildingProvider(
            endpoints: [Self.busy, Self.free], httpClient: client
        )
        let buildings = try await provider.fetchBuildings(
            south: 37.69, west: -122.41, north: 37.71, east: -122.39
        )
        #expect(buildings.count == 1)
    }

    /// With every instance loaded the failure has to name that, rather than surfacing whichever
    /// status the last one happened to answer with as though it were the query's fault.
    @Test func failsOnlyAfterEveryInstanceIsTried() async {
        let client = MockHTTPClient(responses: [
            Self.busy.absoluteString: .init(statusCode: 504),
            Self.free.absoluteString: .init(statusCode: 429)
        ])
        let provider = OSMBuildingProvider(
            endpoints: [Self.busy, Self.free], rounds: 1, httpClient: client
        )
        await #expect(throws: DioramaError.self) {
            _ = try await provider.fetchBuildings(
                south: 37.69, west: -122.41, north: 37.71, east: -122.39
            )
        }
    }

    /// A malformed query answers 400 everywhere, so asking the other instances only delays the
    /// error — and hides which one the user actually needs to read.
    @Test func doesNotShopAroundForAQueryEveryInstanceWillReject() async {
        let client = MockHTTPClient(responses: [
            Self.busy.absoluteString: .init(statusCode: 400),
            Self.free.absoluteString: .init(data: Data(Self.oneBuilding.utf8))
        ])
        let provider = OSMBuildingProvider(
            endpoints: [Self.busy, Self.free], httpClient: client
        )
        await #expect(throws: DioramaError.self) {
            _ = try await provider.fetchBuildings(
                south: 37.69, west: -122.41, north: 37.71, east: -122.39
            )
        }
    }
}

@Suite("Building extrusion")
struct BuildingExtruderTests {
    /// A tile over downtown San Francisco, so the geographic round-trip these tests make happens
    /// somewhere Mercator behaves — near the poles a diorama meter is worth a vanishing slice of
    /// latitude, which would make the test about floating point rather than about buildings.
    private static let tile = (x: 10485, y: 25340)
    private static let zoom = 16

    private func heightField(
        elevations: [Float],
        elevationScale: Float
    ) -> TerrainHeightField {
        TerrainHeightField(
            grids: [ElevationGrid(width: 16, height: 16, values: elevations)],
            tilePositions: [Self.tile],
            anchor: TerrainAnchor(
                mosaicMinTile: SIMD2(Self.tile.x, Self.tile.y),
                tilesWide: 1,
                tilesTall: 1,
                extent: SIMD2(1, 1),
                zoom: Self.zoom
            ),
            elevationScale: elevationScale
        )
    }

    /// A flat height field one tile wide, so `surfaceY` is a constant and the geometry under test is
    /// only the extrusion.
    private func flatHeightField(elevation: Float = 100) -> TerrainHeightField {
        heightField(
            elevations: [Float](repeating: elevation, count: 16 * 16),
            elevationScale: 1
        )
    }

    private func square(_ half: Float, at center: SIMD2<Float> = .zero) -> [SIMD2<Float>] {
        [
            center + SIMD2(-half, -half),
            center + SIMD2(half, -half),
            center + SIMD2(half, half),
            center + SIMD2(-half, half)
        ]
    }

    /// A block is a closed prism, so every triangle has to face out of it. A winding regression is
    /// invisible in vertex counts and very visible on screen — the roof disappears, or the walls do.
    @Test func windsEveryFaceOutward() throws {
        var mesh = IndexedMesh()
        #expect(BuildingExtruder.addBlock(
            square(0.05), height: 0.1, heightField: flatHeightField(), into: &mesh))

        let center = SIMD3<Float>(0, mesh.bounds.center.y, 0)
        var i = 0
        while i + 2 < mesh.indices.count {
            let a = mesh.vertices[Int(mesh.indices[i])].position
            let b = mesh.vertices[Int(mesh.indices[i + 1])].position
            let c = mesh.vertices[Int(mesh.indices[i + 2])].position
            let geometric = simd_cross(b - a, c - a)
            #expect(simd_length(geometric) > 0, "degenerate triangle at index \(i)")
            // Convex prism, so "outward" is "away from the centroid" for every face.
            #expect(simd_dot(geometric, ((a + b + c) / 3) - center) > 0, "inward face at index \(i)")
            i += 3
        }
    }

    /// The stored normals have to agree with the winding, or lighting reads inside-out on a shape
    /// whose silhouette still looks right.
    @Test func storedNormalsMatchTheWinding() {
        var mesh = IndexedMesh()
        _ = BuildingExtruder.addBlock(
            square(0.05), height: 0.1, heightField: flatHeightField(), into: &mesh)

        var i = 0
        while i + 2 < mesh.indices.count {
            let a = mesh.vertices[Int(mesh.indices[i])]
            let b = mesh.vertices[Int(mesh.indices[i + 1])].position
            let c = mesh.vertices[Int(mesh.indices[i + 2])].position
            let geometric = simd_normalize(simd_cross(b - a.position, c - a.position))
            #expect(simd_dot(geometric, a.normal) > 0.99)
            i += 3
        }
    }

    /// OSM stores rings in whichever direction the mapper drew them, so both have to come out the
    /// same. The two meshes should be identical up to the order the corners are listed in.
    @Test func windingOfTheSourceRingDoesNotMatter() {
        let heightField = flatHeightField()
        var forward = IndexedMesh()
        var backward = IndexedMesh()
        _ = BuildingExtruder.addBlock(
            square(0.05), height: 0.1, heightField: heightField, into: &forward)
        _ = BuildingExtruder.addBlock(
            square(0.05).reversed().map { $0 }, height: 0.1, heightField: heightField,
            into: &backward)

        #expect(forward.indices.count == backward.indices.count)
        #expect(forward.bounds.min.y == backward.bounds.min.y)
        #expect(abs(forward.bounds.max.y - backward.bounds.max.y) < 1e-6)
    }

    /// The block stands on the *lowest* ground under its footprint, so a building on a slope is
    /// buried at its uphill corner rather than hovering at its downhill one.
    @Test func standsOnTheLowestGroundUnderTheFootprint() throws {
        // A grid that ramps west to east, so the two sides of the footprint sample different ground.
        var samples = [Float](repeating: 0, count: 16 * 16)
        for row in 0..<16 {
            for column in 0..<16 {
                samples[row * 16 + column] = Float(column) * 10
            }
        }
        let heightField = heightField(elevations: samples, elevationScale: 0.001)

        let outline = square(0.1)
        var mesh = IndexedMesh()
        #expect(BuildingExtruder.addBlock(
            outline, height: 0.05, heightField: heightField, into: &mesh))

        let lowest = outline
            .map { heightField.surfaceY(atX: $0.x, z: $0.y) }
            .min() ?? 0
        // Sunk very slightly, so the seam with undulating ground is never a visible gap.
        #expect(mesh.bounds.min.y <= lowest)
        #expect(mesh.bounds.min.y > lowest - 0.05 * 0.1)
        #expect(abs((mesh.bounds.max.y - mesh.bounds.min.y) - 0.05) < 1e-5)
    }

    @Test func rejectsDegenerateOutlines() {
        var mesh = IndexedMesh()
        #expect(!BuildingExtruder.addBlock(
            [SIMD2(0, 0), SIMD2(1, 0)], height: 0.1, heightField: flatHeightField(), into: &mesh))
        // Three collinear points enclose no area, so there is nothing to extrude.
        #expect(!BuildingExtruder.addBlock(
            [SIMD2(0, 0), SIMD2(1, 0), SIMD2(2, 0)], height: 0.1,
            heightField: flatHeightField(), into: &mesh))
        #expect(mesh.isEmpty)
    }

    /// Footprints crossing the outline are dropped rather than clipped: clipping *against* a
    /// possibly-concave boundary is the direction Sutherland-Hodgman gets wrong.
    @Test func keepsOnlyFootprintsWhollyInsideTheOutline() async throws {
        let heightField = flatHeightField()
        let anchor = heightField.anchor
        let boundary = DioramaBoundary.make(shape: .circular, extent: SIMD2(1, 1))

        func footprint(atDioramaX x: Float, z: Float, half: Float) -> BuildingFootprint {
            BuildingFootprint(
                outline: square(half, at: SIMD2(x, z)).map {
                    anchor.coordinate(forDioramaX: Double($0.x), z: Double($0.y))
                },
                heightMeters: 20
            )
        }

        let (blocks, selection) = await cut(
            [
                footprint(atDioramaX: 0, z: 0, half: 0.02),        // dead centre
                footprint(atDioramaX: 0.49, z: 0, half: 0.02),     // straddling the rim
                footprint(atDioramaX: 2, z: 2, half: 0.02)         // far outside
            ],
            heightField: heightField,
            boundary: boundary
        )

        // All three are extruded — the arena covers the margin ring too — so what is under test is
        // that the selection draws only the one inside the outline.
        #expect(blocks.blocks.count == 3)
        #expect(blocks.droppedDegenerate == 0)
        #expect(selection.kept == 1)
        #expect(selection.droppedOutside == 2)
        for position in positions(selection, in: blocks) {
            #expect(boundary.contains(SIMD2(position.x, position.z)))
        }
    }

    /// Heights ride the terrain's own vertical ruler, so a building and the ground it stands on are
    /// measured the same way — including the region's exaggeration.
    @Test func heightsUseTheTerrainsVerticalScale() {
        let heightField = flatHeightField()
        let doubled = BuildingStyle(exaggeration: 2)
        #expect(BuildingStyle.standard.verticalScale(of: heightField) == heightField.elevationScale)
        #expect(doubled.verticalScale(of: heightField) == heightField.elevationScale * 2)
    }

    /// A footprint whose scaled height rounds to nothing would draw a sheet that z-fights the
    /// terrain, which reads worse than drawing it slightly too tall.
    @Test func neverDrawsABuildingFlat() async throws {
        let heightField = flatHeightField()
        let anchor = heightField.anchor
        let style = BuildingStyle(minimumDrawnHeight: 0.01)
        let (_, selection) = await cut(
            [
                BuildingFootprint(
                    outline: square(0.02).map {
                        anchor.coordinate(forDioramaX: Double($0.x), z: Double($0.y))
                    },
                    heightMeters: 0
                )
            ],
            heightField: heightField,
            boundary: DioramaBoundary.make(shape: .circular, extent: SIMD2(1, 1)),
            style: style
        )
        #expect(selection.kept == 1)
        let span = selection.bounds.max.y - selection.bounds.min.y
        #expect(abs(span - style.minimumDrawnHeight) < 1e-6)
    }

    // MARK: - Panning

    /// Extrudes and selects in one call, the way the store does across two.
    private func cut(
        _ footprints: [BuildingFootprint],
        heightField: TerrainHeightField,
        boundary: DioramaBoundary,
        panOffset: SIMD2<Float> = .zero,
        style: BuildingStyle = .standard
    ) async -> (blocks: BuildingExtruder.Blocks, selection: BuildingExtruder.Selection) {
        let blocks = await BuildingExtruder.build(
            footprints: await BuildingExtruder.project(footprints, anchor: heightField.anchor),
            heightField: heightField,
            style: style
        )
        return (
            blocks,
            await BuildingExtruder.select(from: blocks, boundary: boundary, panOffset: panOffset)
        )
    }

    /// The positions a selection actually draws, which is what the arena's indices address.
    private func positions(
        _ selection: BuildingExtruder.Selection,
        in blocks: BuildingExtruder.Blocks
    ) -> [SIMD3<Float>] {
        selection.indices.map { blocks.vertices[Int($0)].position }
    }

    /// Footprints laid along the X axis, in diorama space, ready to cut at any offset.
    private func planar(atDioramaX offsets: [Float], anchor: TerrainAnchor) async
        -> [BuildingExtruder.PlanarFootprint] {
        await BuildingExtruder.project(
            offsets.map { x in
                BuildingFootprint(
                    outline: square(0.02, at: SIMD2(x, 0)).map {
                        anchor.coordinate(forDioramaX: Double($0.x), z: Double($0.y))
                    },
                    heightMeters: 20
                )
            },
            anchor: anchor
        )
    }

    /// A pan is not a transform applied to a fixed set. The outline stays put and the ground slides
    /// under it, so ground that was outside the rim arrives inside it and has to be cut *in* — which
    /// is the whole reason the fetch covers the margin ring — while ground the outline has left has
    /// to be cut out rather than carried past the rim.
    @Test func aPanCutsInGroundTheOutlineReachesAndCutsOutGroundItLeaves() async throws {
        let heightField = flatHeightField()
        let boundary = DioramaBoundary.make(shape: .circular, extent: SIMD2(1, 1))
        // Spaced further apart than the chunk is wide, so the outline covers at most one of them at
        // a time and there are offsets where it covers none.
        let footprints = await planar(atDioramaX: [-1.2, 0, 1.2], anchor: heightField.anchor)
        // Built once and selected from three times, which is the whole shape of the pan path.
        let blocks = await BuildingExtruder.build(
            footprints: footprints, heightField: heightField, style: .standard
        )

        func draw(at offset: SIMD2<Float>) async -> BuildingExtruder.Selection {
            await BuildingExtruder.select(from: blocks, boundary: boundary, panOffset: offset)
        }

        let atRest = await draw(at: .zero)
        #expect(atRest.kept == 1)
        #expect(abs(atRest.bounds.center.x) < 1e-5)

        // Panned east by 1.2: the far building is over the chunk now, the middle one has left.
        let panned = await draw(at: SIMD2(1.2, 0))
        #expect(panned.kept == 1)
        // Positions stay in ground space — the entity's transform is what carries them onto the
        // chunk — so the surviving block is the one that was at x = 1.2 all along.
        #expect(abs(panned.bounds.center.x - 1.2) < 1e-5)

        // Panned to where neither reaches, so the chunk is genuinely bare rather than showing a
        // block that has drifted past the rim.
        let between = await draw(at: SIMD2(0.6, 0))
        #expect(between.kept == 0)
        #expect(between.isEmpty)
    }

    /// A selection is made in ground space, which is what lets a stale one be drawn without a jump:
    /// the store selects off the main actor and a drag outruns it, so what is on screen is routinely
    /// one step behind the transform carrying it. Behind is fine; *displaced* would not be.
    @Test func whatIsDrawnIsIndependentOfTheOffsetItWasSelectedAt() async throws {
        let heightField = flatHeightField()
        let boundary = DioramaBoundary.make(shape: .circular, extent: SIMD2(1, 1))
        // Well inside the outline at both offsets, so both selections keep it and only the
        // arithmetic that placed it is under test.
        let footprints = await planar(atDioramaX: [0.3], anchor: heightField.anchor)
        let blocks = await BuildingExtruder.build(
            footprints: footprints, heightField: heightField, style: .standard
        )

        let early = await BuildingExtruder.select(from: blocks, boundary: boundary)
        let late = await BuildingExtruder.select(
            from: blocks, boundary: boundary, panOffset: SIMD2(0.05, 0.02)
        )

        #expect(early.kept == 1)
        #expect(late.kept == 1)
        #expect(positions(early, in: blocks) == positions(late, in: blocks))
    }

    /// Most of a downtown fetch is nowhere near the outline, so a cut rejects on bounding boxes
    /// before testing corners against the ring. A box test that is too eager deletes buildings that
    /// belong on the chunk, and it does it silently — the count still looks plausible.
    @Test func rejectingOnBoxesAgreesWithTestingEveryCorner() async throws {
        let heightField = flatHeightField()
        let anchor = heightField.anchor
        // Both shapes, because they exercise the box test from opposite sides. On a circle the box
        // is slack — a footprint straddling the box's edge sits at the circle's extreme point and
        // is outside the outline anyway — so an over-eager box goes unnoticed there. On a rectangle
        // the box *is* the outline, and every rejection it makes is load-bearing.
        let boundaries = [
            DioramaBoundary.make(shape: .circular, extent: SIMD2(1, 1)),
            DioramaBoundary.make(shape: .rectangular(width: 1, depth: 1), extent: SIMD2(1, 1)),
        ]

        // A lattice straddling the rim at every angle, so the disagreements a box test could cause
        // are the ones actually sampled.
        var centers: [Float] = []
        for step in -12...12 { centers.append(Float(step) * 0.05) }
        var placed: [SIMD2<Float>] = []
        for x in centers {
            for z in centers { placed.append(SIMD2(x, z)) }
        }
        let footprints = await BuildingExtruder.project(
            placed.map { center in
                BuildingFootprint(
                    outline: square(0.02, at: center).map {
                        anchor.coordinate(forDioramaX: Double($0.x), z: Double($0.y))
                    },
                    heightMeters: 20
                )
            },
            anchor: anchor
        )

        let blocks = await BuildingExtruder.build(
            footprints: footprints, heightField: heightField, style: .standard
        )
        #expect(blocks.blocks.count + blocks.droppedDegenerate == footprints.count)

        for boundary in boundaries {
            for offset in [SIMD2<Float>.zero, SIMD2(0.3, 0), SIMD2(-0.2, 0.4), SIMD2(2, 2)] {
                let selection = await BuildingExtruder.select(
                    from: blocks, boundary: boundary, panOffset: offset
                )
                let expected = blocks.blocks.count { block in
                    block.outline.allSatisfy { boundary.contains($0 - offset) }
                }
                #expect(selection.kept == expected, "at offset \(offset)")
                // Nothing may go missing between the two counts either.
                #expect(selection.kept + selection.droppedOutside == blocks.blocks.count)
            }
        }
    }

    /// Projection happens once and every later cut reads it, so it has to name the same diorama
    /// positions the anchor does — and carry the box those corners actually span.
    @Test func projectionKeepsThePositionsTheAnchorNames() async throws {
        let anchor = flatHeightField().anchor
        let corners = square(0.02, at: SIMD2(0.1, -0.3))
        let footprints = await BuildingExtruder.project(
            [
                BuildingFootprint(
                    outline: corners.map {
                        anchor.coordinate(forDioramaX: Double($0.x), z: Double($0.y))
                    },
                    heightMeters: 20
                ),
                // Fewer than three corners could never be extruded, so it is dropped here rather
                // than counted as a loss on every cut.
                BuildingFootprint(
                    outline: [anchor.coordinate(forDioramaX: 0, z: 0)], heightMeters: 20
                )
            ],
            anchor: anchor
        )

        let projected = try #require(footprints.first)
        #expect(footprints.count == 1)
        #expect(projected.outline.count == corners.count)
        for (made, wanted) in zip(projected.outline, corners) {
            #expect(simd_distance(made, wanted) < 1e-5)
        }
        #expect(simd_distance(projected.minCorner, SIMD2(0.08, -0.32)) < 1e-5)
        #expect(simd_distance(projected.maxCorner, SIMD2(0.12, -0.28)) < 1e-5)
        #expect(projected.heightMeters == 20)
    }
}
