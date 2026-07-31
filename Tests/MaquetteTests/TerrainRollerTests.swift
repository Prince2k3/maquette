import CoreGraphics
import Foundation
import ImageIO
import Testing
import simd
@testable import Maquette

/// A tile server whose elevation says which tile it came from, so a sample can be traced back to
/// the request that produced it.
private struct IdentifyingTileProvider: TileProvider {
    let providerIdentifier: String
    let size: Int

    func fetchTile(x: Int, y: Int, zoom: Int) async throws -> Data {
        TerrainRollerTests.terrariumPNG(elevation: Float(x * 100 + y), size: size)
    }
}

/// A tile server that refuses one column, standing in for a fetch that fails.
private struct FailingColumnProvider: TileProvider {
    let providerIdentifier: String
    let size: Int
    let failingX: Int

    func fetchTile(x: Int, y: Int, zoom: Int) async throws -> Data {
        guard x != failingX else { throw DioramaError.networkFailure(message: "no tile") }
        return TerrainRollerTests.terrariumPNG(elevation: Float(x * 100 + y), size: size)
    }
}

@Suite("Terrain Roller Tests")
struct TerrainRollerTests {
    /// One diorama meter per tile, with diorama X/Z = 0 at the corner of tile (8, 8).
    private static let anchor = TerrainAnchor(
        zoom: 4,
        originTile: SIMD2(8, 8),
        tilesPerDioramaMeter: SIMD2(1, 1)
    )

    private func roller(
        identifier: String,
        provider: (any TileProvider)? = nil,
        margin: Int = 1,
        chunkMax: SIMD2<Float> = SIMD2(1, 1)
    ) -> TerrainRoller {
        let tiles = provider ?? IdentifyingTileProvider(providerIdentifier: identifier, size: 8)
        return TerrainRoller(
            zoom: 4,
            anchor: Self.anchor,
            elevationScale: 1,
            baselineElevation: 0,
            chunkMin: SIMD2(0, 0),
            chunkMax: chunkMax,
            marginTiles: SIMD2(margin, margin),
            terrainProvider: tiles,
            satelliteProvider: IdentifyingTileProvider(
                providerIdentifier: "\(identifier)-imagery",
                size: 8
            ),
            cache: TileCache(maxMemoryEntries: 200)
        )
    }

    // MARK: - Windows

    @Test("A window contains a window inside it and not one that pokes out")
    func windowContainment() {
        let outer = TerrainTileWindow(minX: 0, minY: 0, maxX: 4, maxY: 4)
        #expect(outer.contains(TerrainTileWindow(minX: 1, minY: 1, maxX: 3, maxY: 3)))
        #expect(outer.contains(outer))
        #expect(!outer.contains(TerrainTileWindow(minX: 1, minY: 1, maxX: 5, maxY: 3)))
        #expect(!outer.contains(TerrainTileWindow(minX: -1, minY: 1, maxX: 3, maxY: 3)))
    }

    @Test("The window follows the pan offset a tile at a time")
    func windowFollowsTheOffset() {
        let roller = roller(identifier: "roll-window")

        // The chunk spans tiles 8...9, and the margin adds one either way.
        let resting = roller.window(forPanOffset: .zero)
        #expect(resting == TerrainTileWindow(minX: 7, minY: 7, maxX: 10, maxY: 10))

        // Three tiles east and two north, at one diorama meter per tile.
        let panned = roller.window(forPanOffset: SIMD2(3, -2))
        #expect(panned == TerrainTileWindow(minX: 10, minY: 5, maxX: 13, maxY: 8))
    }

    @Test("The margin ring holds a tile of pan ahead of the chunk")
    func marginRunsAheadOfTheChunk() {
        // The ring is a prefetch, not roll-freedom: a roll fires as soon as the *ring* would move,
        // which is a whole tile before the chunk itself reaches unloaded ground. That head start is
        // the reason a pan never has to wait on the network.
        let ringed = roller(identifier: "roll-margin")
        let bare = roller(identifier: "roll-margin-bare", margin: 0)
        let resting = ringed.window(forPanOffset: .zero)

        for step in [Float(0.9), 0.5, 0, -0.5, -0.9] {
            let sampled = bare.window(forPanOffset: SIMD2(step, step))
            #expect(resting.contains(sampled), "chunk left the loaded ground at \(step)")
        }

        // A tile further out and it has genuinely run off the ring.
        #expect(!resting.contains(bare.window(forPanOffset: SIMD2(2.5, 0))))
    }

    @Test("Rows stop at the poles, columns never do")
    func rowsClampColumnsWrap() {
        let roller = roller(identifier: "roll-poles")

        // Zoom 4 has 16 rows, so panning north past the top clamps rather than running off.
        let north = roller.window(forPanOffset: SIMD2(0, -100))
        #expect(north.minY == 0)
        #expect(north.maxY == 0)

        // Columns keep counting: the window is allowed to run past the antimeridian, because
        // that is a real place and the request is what wraps.
        let east = roller.window(forPanOffset: SIMD2(100, 0))
        #expect(east.minX == 107)
        #expect(east.maxX == 110)
    }

    // MARK: - Pan Limits

    @Test("The pan stops where the resident tiles do")
    func panLimitsKeepTheChunkOnResidentGround() {
        let roller = roller(identifier: "roll-limits")
        let window = TerrainTileWindow(minX: 7, minY: 7, maxX: 10, maxY: 10)
        let limits = roller.panLimits(within: window)

        // The chunk spans one tile-width; the window spans four, so there are three to slide in.
        #expect(limits.low == SIMD2<Float>(-1, -1))
        #expect(limits.high == SIMD2<Float>(2, 2))

        // At either extreme the chunk still sits entirely on tiles the window holds.
        for offset in [limits.low, limits.high] {
            let west = roller.anchor.tilePoint(
                forDioramaX: Double(offset.x), z: Double(offset.y)
            )
            let east = roller.anchor.tilePoint(
                forDioramaX: Double(1 + offset.x), z: Double(1 + offset.y)
            )
            #expect(west.x >= Double(window.minX))
            #expect(west.y >= Double(window.minY))
            #expect(east.x <= Double(window.maxX + 1))
            #expect(east.y <= Double(window.maxY + 1))
        }

        // A step past the extreme hangs the chunk off the edge, which is what the clamp exists to
        // prevent: sampling out there smears the border and then snaps when the roll lands.
        let overhang = roller.anchor.tilePoint(
            forDioramaX: Double(1 + limits.high.x + 0.5), z: 0
        )
        #expect(overhang.x > Double(window.maxX + 1))
    }

    @Test("A window narrower than the chunk pins it rather than inverting the range")
    func panLimitsCollapseOnATooSmallWindow() {
        // Three tiles of chunk over one tile of ground: no offset puts it entirely on resident
        // tiles, so the range would come back inverted if it were taken at face value.
        let roller = roller(identifier: "roll-narrow", chunkMax: SIMD2(3, 3))
        let limits = roller.panLimits(within: TerrainTileWindow(minX: 8, minY: 8, maxX: 8, maxY: 8))

        #expect(limits.low.x <= limits.high.x)
        #expect(limits.low.y <= limits.high.y)
        // Pinned to the middle of what there is: the chunk's centre over the tile's centre.
        #expect(limits.low == limits.high)
        #expect(limits.low == SIMD2<Float>(-1, -1))
    }

    @Test("Clamping stops the pan at the frontier and lets it come back")
    func clampHoldsTheChunkOnResidentGround() {
        let roller = roller(identifier: "roll-clamp")
        let window = TerrainTileWindow(minX: 7, minY: 7, maxX: 10, maxY: 10)

        // Inside the range, the target is taken as given.
        #expect(roller.clamp(SIMD2(0.5, 0.5), from: .zero, within: window) == SIMD2<Float>(0.5, 0.5))

        // Past it, the pan stops at the edge of the tiles rather than sampling off them.
        #expect(roller.clamp(SIMD2(9, 9), from: SIMD2(1.9, 1.9), within: window) == SIMD2<Float>(2, 2))
        #expect(roller.clamp(SIMD2(-9, -9), from: SIMD2(-0.9, -0.9), within: window) == SIMD2<Float>(-1, -1))
    }

    @Test("A window that no longer covers the chunk does not move it")
    func clampNeverRelocatesTheGroundAlreadyShown() {
        // The offset a drag reached, against a window that does not reach it — which is what a
        // failed tile fetch or a drag that outran the roll leaves behind. Clamping to the bare
        // limits would haul the chunk back to 2, and the ground would jump on the next touch.
        let roller = roller(identifier: "roll-stranded")
        let window = TerrainTileWindow(minX: 7, minY: 7, maxX: 10, maxY: 10)
        let stranded = SIMD2<Float>(5, 5)
        #expect(roller.panLimits(within: window).high == SIMD2<Float>(2, 2))

        // Standing still stays still, and so does the smallest movement outward.
        #expect(roller.clamp(stranded, from: stranded, within: window) == stranded)
        #expect(roller.clamp(SIMD2(5.001, 5.001), from: stranded, within: window) == stranded)

        // Coming back toward the resident ground is never obstructed.
        #expect(roller.clamp(SIMD2(4, 4), from: stranded, within: window) == SIMD2<Float>(4, 4))
        #expect(roller.clamp(SIMD2(-9, -9), from: stranded, within: window) == SIMD2<Float>(-1, -1))
    }

    @Test("A window narrower than the chunk pins the pan without teleporting it")
    func clampOnATooSmallWindowDoesNotTeleport() {
        // The collapse case: the limits are a single point, so an absolute clamp would drop the
        // chunk onto it from wherever it happened to be.
        let roller = roller(identifier: "roll-narrow-clamp", chunkMax: SIMD2(3, 3))
        let window = TerrainTileWindow(minX: 8, minY: 8, maxX: 8, maxY: 8)
        let current = SIMD2<Float>(0.75, 0.75)
        #expect(roller.panLimits(within: window).low == SIMD2<Float>(-1, -1))

        #expect(roller.clamp(current, from: current, within: window) == current)
        #expect(roller.clamp(SIMD2(0.8, 0.8), from: current, within: window) == current)
        #expect(roller.clamp(SIMD2(0.5, 0.5), from: current, within: window) == SIMD2<Float>(0.5, 0.5))
    }

    // MARK: - Loading

    @Test("Rolling in more ground does not move the ground already there")
    func rollingDoesNotShiftTheGround() async throws {
        // The invariant the whole anchor exists for, exercised through the real fetch, stitch and
        // height-field build rather than against a synthetic mosaic.
        let roller = roller(identifier: "roll-stable")

        let narrow = try #require(
            await roller.load(window: roller.window(forPanOffset: .zero), have: TerrainTileSet())
        )
        // Deliberately off-centre from the first, because that is what a roll is. A window centred
        // on the old one would agree even under a mosaic-derived mapping, and prove nothing.
        let rolled = try #require(
            await roller.load(
                window: TerrainTileWindow(minX: 8, minY: 6, maxX: 12, maxY: 11),
                have: narrow.tiles
            )
        )

        // Tile centres, so the comparison is not decided by the edges the stitcher reconciles
        // against whichever neighbours happen to be loaded.
        for x in [Float(0.5), 1.5] {
            for z in [Float(0.5), 1.5] {
                #expect(
                    narrow.heightField.rawElevation(atX: x, z: z)
                        == rolled.heightField.rawElevation(atX: x, z: z)
                )
            }
        }
    }

    @Test("Rolling in more ground does not move the imagery already there")
    func rollingDoesNotShiftTheImagery() async throws {
        // The elevation invariant above has a twin that is easy to forget, because it is the one
        // the eye actually reads: a diorama point must keep naming the same *pixel*, not merely the
        // same height. Texture coordinates are window-relative — 0...1 across whatever mosaic is
        // resident — so the number legitimately changes on every roll. What must not change is the
        // ground it lands on, which is the coordinate scaled back into absolute tile space.
        let roller = roller(identifier: "roll-imagery-stable")

        let narrow = try #require(
            await roller.load(window: roller.window(forPanOffset: .zero), have: TerrainTileSet())
        )
        // Off-centre and a different *shape* (4x4 becomes 5x5), because the shape is the divisor.
        let rolled = try #require(
            await roller.load(
                window: TerrainTileWindow(minX: 8, minY: 6, maxX: 12, maxY: 10),
                have: narrow.tiles
            )
        )

        for x in [Float(0.25), 0.5, 1.5, 1.75] {
            for z in [Float(0.25), 0.5, 1.5, 1.75] {
                let before = Self.sampledTilePoint(of: narrow.heightField, atX: x, z: z)
                let after = Self.sampledTilePoint(of: rolled.heightField, atX: x, z: z)
                #expect(
                    abs(before.x - after.x) < 1e-4 && abs(before.y - after.y) < 1e-4,
                    "imagery moved at (\(x), \(z)): \(before) became \(after)"
                )
            }
        }
    }

    @Test("A point's imagery comes from the same tile as its elevation")
    func imageryNamesTheSameTileAsElevation() async throws {
        // The two halves of the surface are sampled through different conventions and only agree by
        // construction: the height field indexes grids from the north, while RealityKit reads a
        // texture from the bottom of the image up. A mosaic drawn north-up is therefore sampled
        // upside down unless V is flipped, and the mirror is nearly invisible on its own — aerial
        // imagery still reads as aerial imagery — which is the same trap `GLBParser` documents.
        //
        // It stops being invisible the moment the window's *rows* move. The mirror reflects about
        // the window's middle row, so shifting the window one tile north moves the ground the
        // texture samples two tiles south. Columns are unaffected, which is exactly why panning
        // east for five kilometres looked perfect and panning north jumped.
        let roller = roller(identifier: "roll-uv-tile")
        let roll = try #require(
            await roller.load(window: roller.window(forPanOffset: .zero), have: TerrainTileSet())
        )

        for x in [Float(0.5), 1.5] {
            for z in [Float(0.5), 1.5] {
                // The provider encodes the tile it came from as `x * 100 + y`.
                let elevation = Int(roll.heightField.rawElevation(atX: x, z: z).rounded())
                let elevationTile = (x: elevation / 100, y: elevation % 100)
                let imageryTile = Self.sampledTile(of: roll.heightField, atX: x, z: z)
                #expect(
                    imageryTile == elevationTile,
                    "at (\(x), \(z)) imagery reads tile \(imageryTile) but the ground is \(elevationTile)"
                )
            }
        }
    }

    /// The ground, in absolute tile coordinates, whose pixels RealityKit actually draws at a
    /// diorama point.
    ///
    /// A texture coordinate is relative to the resident mosaic, so recovering the ground means
    /// undoing both the window — scale by its size, shift by its corner — and the vertical
    /// convention: the mosaic is composited north-up while RealityKit's texture origin is the
    /// *bottom* left, so V counts up from the image's southern edge.
    private static func sampledTilePoint(
        of field: TerrainHeightField,
        atX x: Float,
        z: Float
    ) -> SIMD2<Float> {
        let minTileX = field.tilePositions.map(\.x).min() ?? 0
        let minTileY = field.tilePositions.map(\.y).min() ?? 0
        let wide = Float((field.tilePositions.map(\.x).max() ?? 0) - minTileX + 1)
        let tall = Float((field.tilePositions.map(\.y).max() ?? 0) - minTileY + 1)
        let uv = field.textureCoordinate(atX: x, z: z)
        return SIMD2(uv.x * wide + Float(minTileX), (1 - uv.y) * tall + Float(minTileY))
    }

    /// The tile whose pixels RealityKit actually draws at a diorama point.
    private static func sampledTile(
        of field: TerrainHeightField,
        atX x: Float,
        z: Float
    ) -> (x: Int, y: Int) {
        let point = sampledTilePoint(of: field, atX: x, z: z)
        return (x: Int(point.x.rounded(.down)), y: Int(point.y.rounded(.down)))
    }

    @Test("A rolled surface reads the tiles the window asked for")
    func rolledSurfaceReadsTheRequestedTiles() async throws {
        let roller = roller(identifier: "roll-identity")
        let roll = try #require(
            await roller.load(window: roller.window(forPanOffset: .zero), have: TerrainTileSet())
        )

        #expect(roll.window == TerrainTileWindow(minX: 7, minY: 7, maxX: 10, maxY: 10))
        // Diorama (0.5, 0.5) is the middle of tile (8, 8), which encodes 8 * 100 + 8.
        #expect(abs(roll.heightField.rawElevation(atX: 0.5, z: 0.5) - 808) < 1)
        #expect(abs(roll.heightField.rawElevation(atX: 1.5, z: 0.5) - 908) < 1)
        #expect(abs(roll.heightField.rawElevation(atX: 0.5, z: 1.5) - 809) < 1)
        #expect(roll.imagery != nil)
    }

    @Test("Panning past the antimeridian keeps fetching real tiles")
    func columnsWrapOnFetch() async throws {
        // Zoom 4 is 16 columns wide, so column -1 is column 15. Without the wrap the request goes
        // out with a negative column and the ground simply stops at the meridian.
        let roller = roller(identifier: "roll-wrap")
        let roll = try #require(
            await roller.load(
                window: TerrainTileWindow(minX: -2, minY: 8, maxX: 0, maxY: 8),
                have: TerrainTileSet()
            )
        )

        // Diorama X = -8.5 is the middle of window column -1, which must carry column 15's ground.
        #expect(abs(roll.heightField.rawElevation(atX: -8.5, z: 0.5) - 1508) < 1)
        // And column -2 is column 14, so the two are neighbours rather than a repeat.
        #expect(abs(roll.heightField.rawElevation(atX: -9.5, z: 0.5) - 1408) < 1)
    }

    @Test("A tile that fails to fetch shrinks the window instead of failing the roll")
    func failedTilesAreSkipped() async throws {
        let failing = FailingColumnProvider(
            providerIdentifier: "roll-fail-terrain",
            size: 8,
            failingX: 10
        )
        let roller = roller(identifier: "roll-fail", provider: failing)
        let roll = try #require(
            await roller.load(window: roller.window(forPanOffset: .zero), have: TerrainTileSet())
        )

        // The column that refused is simply absent, and the height field covers what arrived —
        // which is what keeps the imagery composited over exactly the tiles the elevation holds.
        #expect(roll.window == TerrainTileWindow(minX: 7, minY: 7, maxX: 9, maxY: 10))
        #expect(roll.tiles.grids[TileCoordinate(x: 10, y: 8)] == nil)
        #expect(abs(roll.heightField.rawElevation(atX: 0.5, z: 0.5) - 808) < 1)
    }

    @Test("A tile that fails inside the window leaves a hole rather than shrinking it")
    func failedInteriorTilesLeaveAHole() async throws {
        // The edge case above shrinks the window, which is harmless. A column that refuses from the
        // middle cannot shrink anything: the bounding box still spans it, so the mosaic keeps a slot
        // nothing was ever drawn into.
        let failing = FailingColumnProvider(
            providerIdentifier: "roll-hole-terrain",
            size: 8,
            failingX: 8
        )
        let roller = roller(identifier: "roll-hole", provider: failing)
        let roll = try #require(
            await roller.load(window: roller.window(forPanOffset: .zero), have: TerrainTileSet())
        )

        #expect(roll.window == TerrainTileWindow(minX: 7, minY: 7, maxX: 10, maxY: 10))
        #expect(roll.tiles.grids[TileCoordinate(x: 8, y: 8)] == nil)

        // Tile 8 is diorama X 0...1, so the chunk sits directly over the gap. Elevation there falls
        // back to the field's minimum while its neighbours carry real ground.
        let inHole = roll.heightField.rawElevation(atX: 0.5, z: 0.5)
        let beside = roll.heightField.rawElevation(atX: 1.5, z: 0.5)
        #expect(inHole < beside)

        // The imagery has the same gap, and nothing was drawn into it.
        #expect(roll.tiles.imagery[TileCoordinate(x: 8, y: 8)] == nil)
        let mosaic = try #require(roll.imagery)
        #expect(mosaic.width == 4 * 8)
    }

    // MARK: - Fixtures

    /// A Terrarium-encoded PNG whose every pixel carries the same elevation.
    static func terrariumPNG(elevation: Float, size: Int) -> Data {
        // Terrarium packs elevation as `r * 256 + g + b / 256 - 32768`; whole meters fit in R and G.
        let raw = Int((elevation + 32_768).rounded())
        let red = UInt8((raw >> 8) & 0xFF)
        let green = UInt8(raw & 0xFF)

        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for index in 0..<(size * size) {
            pixels[index * 4] = red
            pixels[index * 4 + 1] = green
            pixels[index * 4 + 2] = 0
            pixels[index * 4 + 3] = 255
        }

        let image: CGImage? = pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        guard let image else { return Data() }

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, "public.png" as CFString, 1, nil
        ) else {
            return Data()
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return encoded as Data
    }
}
