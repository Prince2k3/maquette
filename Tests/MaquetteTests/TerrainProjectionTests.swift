import CoreLocation
import Foundation
import Testing
import simd
@testable import Maquette

@Suite("Terrain Projection Tests")
struct TerrainProjectionTests {
    private static let center = CLLocationCoordinate2D(latitude: 36.1069, longitude: -112.1129)
    private static let zoom = 11
    private static let radiusMeters: Double = 5000
    private static let physicalSize: Float = 0.8

    /// A synthetic elevation grid where elevation rises with both row and column.
    private func makeSyntheticGrid(width: Int = 256, height: Int = 256) -> ElevationGrid {
        var values = [Float](repeating: 0, count: width * height)
        for row in 0..<height {
            for col in 0..<width {
                values[row * width + col] = Float(row) + Float(col) * 0.1
            }
        }
        return ElevationGrid(width: width, height: height, values: values)
    }

    /// A projection over a single tile of the given grid, centred on the Grand Canyon.
    ///
    /// Uses the mosaic-derived mapping — the loaded tiles *are* the region — which is the right one
    /// for a chunk whose tiles never change and keeps the arithmetic checkable by hand.
    private func makeProjection(
        grid: ElevationGrid,
        exaggeration: Float = 1.0,
        baseline: Float = 0
    ) -> TerrainProjection {
        let tile = TileMath.tileXY(for: Coordinate(Self.center), zoom: Self.zoom)
        let heightField = TerrainHeightField(
            grids: [grid],
            tilePositions: [(x: tile.x, y: tile.y)],
            extent: SIMD2(Self.physicalSize, Self.physicalSize),
            elevationScale: Self.physicalSize / Float(Self.radiusMeters * 2) * exaggeration,
            baselineElevation: baseline,
            zoom: Self.zoom
        )
        return TerrainProjection(heightField: heightField)
    }

    private func makeProjection() -> TerrainProjection {
        makeProjection(grid: makeSyntheticGrid())
    }

    @Test("Center coordinate sits on the surface")
    func centerElevation() {
        let projection = makeProjection()
        #expect(projection.elevation(at: Self.center) != nil)
    }

    @Test("Elevation at center is non-negative")
    func centerElevationNonNegative() throws {
        let projection = makeProjection()
        let elevation = try #require(projection.elevation(at: Self.center))
        #expect(elevation >= 0)
    }

    @Test("Coordinate off the loaded ground has no surface")
    func outsideBoundsReturnsNil() {
        let projection = makeProjection()
        // Null Island, half a world from the loaded tile.
        #expect(projection.elevation(at: CLLocationCoordinate2D(latitude: 0, longitude: 0)) == nil)
    }

    @Test("Known elevation produces the expected Y value")
    func knownElevation() throws {
        let flat = ElevationGrid(
            width: 256,
            height: 256,
            values: [Float](repeating: 100.0, count: 256 * 256)
        )
        let projection = makeProjection(grid: flat)

        let elevation = try #require(projection.elevation(at: Self.center))
        // (100 - 0) * (0.8 / 10000) * 1.0
        let expected = 100.0 * (Self.physicalSize / Float(Self.radiusMeters * 2))
        #expect(abs(elevation - expected) < 0.001)
    }

    @Test("Elevation interpolates between grid cells")
    func bilinearInterpolation() throws {
        var values = [Float](repeating: 0, count: 16)
        for row in 0..<4 {
            for col in 0..<4 {
                values[row * 4 + col] = Float(col) * 100.0
            }
        }
        let projection = makeProjection(grid: ElevationGrid(width: 4, height: 4, values: values))

        let elevation = try #require(projection.elevation(at: Self.center))
        #expect(elevation >= 0)
        #expect(elevation <= 300.0 * (Self.physicalSize / Float(Self.radiusMeters * 2)))
    }

    @Test("Zero exaggeration flattens the surface")
    func zeroExaggeration() throws {
        let grid = ElevationGrid(
            width: 16,
            height: 16,
            values: [Float](repeating: 500.0, count: 16 * 16)
        )
        let projection = makeProjection(grid: grid, exaggeration: 0)
        #expect(try #require(projection.elevation(at: Self.center)) == 0)
    }

    @Test("Elevation is measured from the baseline, not from sea level")
    func baselineIsTheOrigin() throws {
        let grid = ElevationGrid(
            width: 16,
            height: 16,
            values: [Float](repeating: 1500.0, count: 16 * 16)
        )
        let projection = makeProjection(grid: grid, baseline: 1500)
        // Ground at exactly the baseline is diorama Y = 0, the convention the whole library shares.
        #expect(abs(try #require(projection.elevation(at: Self.center))) < 1e-6)
        #expect(abs(projection.y(forElevation: 1500)) < 1e-6)
    }

    @Test("Center of the diorama lands at the origin of its horizontal plane")
    func centerIsTheOrigin() {
        let projection = makeProjection()
        let point = projection.point(for: Coordinate(Self.center))
        // The mosaic-derived mapping centres the tile window, and the tile the centre falls in is
        // not centred on it, so this is only approximate — but it is within half a tile.
        #expect(abs(point.x) < Self.physicalSize / 2)
        #expect(abs(point.y) < Self.physicalSize / 2)
    }

    @Test("East is +X and north is -Z")
    func axisConvention() {
        let projection = makeProjection()
        let origin = projection.point(for: Coordinate(Self.center))
        let east = projection.point(
            for: Coordinate(latitude: Self.center.latitude, longitude: Self.center.longitude + 0.01)
        )
        let north = projection.point(
            for: Coordinate(latitude: Self.center.latitude + 0.01, longitude: Self.center.longitude)
        )
        #expect(east.x > origin.x)
        #expect(north.y < origin.y)
    }

    @Test("Panning moves a coordinate with the ground it sits on")
    func panningCarriesCoordinates() throws {
        let grid = makeSyntheticGrid()
        var projection = makeProjection(grid: grid)

        let before = try #require(projection.position(for: Coordinate(Self.center)))
        let offset = SIMD2<Float>(0.05, -0.03)
        projection.panOffset = offset
        let after = try #require(projection.position(for: Coordinate(Self.center)))

        // A coordinate is drawn at its anchored point *minus* the offset: the outline stays put and
        // the ground slides beneath it. Getting this backwards moves pins at twice the rate and in
        // the wrong direction, which still looks like a pin on terrain.
        #expect(abs((after.x - before.x) - -offset.x) < 1e-5)
        #expect(abs((after.z - before.z) - -offset.y) < 1e-5)
        // And it keeps its own ground, so the height it reads is unchanged.
        #expect(abs(after.y - before.y) < 1e-5)
    }

    @Test("The surface is sampled where the ground is, not where it is drawn")
    func surfaceFollowsTheGround() {
        var projection = makeProjection()
        let offset = SIMD2<Float>(0.05, 0.02)
        let drawn = SIMD2<Float>(0.1, -0.04)

        let still = projection.surfaceY(atX: drawn.x, z: drawn.y)
        projection.panOffset = offset
        let panned = projection.surfaceY(atX: drawn.x - offset.x, z: drawn.y - offset.y)

        // The point drawn where `drawn` was before the pan is now `drawn - offset`, and it must
        // still read the same ground.
        #expect(still != nil)
        #expect(panned != nil)
        #expect(abs(still! - panned!) < 1e-6)
    }

    @Test("Altitude references measure from different places")
    func altitudeReferences() throws {
        let flat = ElevationGrid(
            width: 16,
            height: 16,
            values: [Float](repeating: 1000.0, count: 16 * 16)
        )
        // Baseline at 1000 m, so the ground is at diorama Y = 0 and the arithmetic is readable.
        let projection = makeProjection(grid: flat, baseline: 1000)
        let scale = Self.physicalSize / Float(Self.radiusMeters * 2)
        let coordinate = Coordinate(Self.center, altitude: 500)

        let clamped = try #require(projection.position(for: coordinate, altitude: .clampToGround))
        #expect(abs(clamped.y) < 1e-6)

        let relative = try #require(
            projection.position(for: coordinate, altitude: .relativeToGround)
        )
        #expect(abs(relative.y - 500 * scale) < 1e-5)

        // 500 m above sea level against a 1000 m baseline is 500 m *below* the ground.
        let absolute = try #require(projection.position(for: coordinate, altitude: .absolute))
        #expect(abs(absolute.y - -500 * scale) < 1e-5)
    }
}
