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
        margin: Int = 1
    ) -> TerrainRoller {
        let tiles = provider ?? IdentifyingTileProvider(providerIdentifier: identifier, size: 8)
        return TerrainRoller(
            zoom: 4,
            anchor: Self.anchor,
            elevationScale: 1,
            baselineElevation: 0,
            chunkMin: SIMD2(0, 0),
            chunkMax: SIMD2(1, 1),
            marginTiles: SIMD2(margin, margin),
            terrainProvider: tiles,
            satelliteProvider: IdentifyingTileProvider(
                providerIdentifier: "\(identifier)-imagery",
                size: 8
            ),
            decodesMapTilerTerrain: false,
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
