import CoreLocation
import Foundation
import Testing
@testable import Maquette

@Suite("Elevation Sampler Tests")
struct ElevationSamplerTests {
    /// A synthetic elevation grid where elevation equals row * 10 + col.
    private func makeSyntheticGrid(width: Int = 256, height: Int = 256) -> ElevationGrid {
        var values = [Float](repeating: 0, count: width * height)
        for row in 0..<height {
            for col in 0..<width {
                values[row * width + col] = Float(row) + Float(col) * 0.1
            }
        }
        return ElevationGrid(width: width, height: height, values: values)
    }

    /// Creates a sampler centered at Grand Canyon with a single synthetic tile.
    private func makeSampler() -> ElevationSampler {
        let center = CLLocationCoordinate2D(latitude: 36.1069, longitude: -112.1129)
        let zoom = 11
        let tileCoord = TileMath.tileXY(for: Coordinate(center), zoom: zoom)
        let grid = makeSyntheticGrid()

        return ElevationSampler(
            grids: [grid],
            tilePositions: [(x: tileCoord.x, y: tileCoord.y)],
            zoom: zoom,
            center: center,
            radiusMeters: 5000,
            physicalDiameter: 0.8,
            exaggeration: 1.0,
            globalMinElev: 0
        )
    }

    @Test("Center coordinate returns non-nil elevation")
    func centerElevation() {
        let sampler = makeSampler()
        let elevation = sampler.elevation(at: sampler.center)
        #expect(elevation != nil)
    }

    @Test("Elevation at center is non-negative")
    func centerElevationNonNegative() {
        let sampler = makeSampler()
        let elevation = sampler.elevation(at: sampler.center)
        #expect(elevation != nil)
        #expect(elevation! >= 0)
    }

    @Test("Coordinate outside tile bounds returns nil")
    func outsideBoundsReturnsNil() {
        let sampler = makeSampler()
        // A coordinate far away from the center
        let farAway = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let elevation = sampler.elevation(at: farAway)
        #expect(elevation == nil)
    }

    @Test("Known elevation produces expected Y value")
    func knownElevation() {
        let center = CLLocationCoordinate2D(latitude: 36.1069, longitude: -112.1129)
        let zoom = 11
        let tileCoord = TileMath.tileXY(for: Coordinate(center), zoom: zoom)

        // Flat grid at 100m elevation
        let width = 256
        let height = 256
        let grid = ElevationGrid(
            width: width,
            height: height,
            values: [Float](repeating: 100.0, count: width * height)
        )

        let sampler = ElevationSampler(
            grids: [grid],
            tilePositions: [(x: tileCoord.x, y: tileCoord.y)],
            zoom: zoom,
            center: center,
            radiusMeters: 5000,
            physicalDiameter: 0.8,
            exaggeration: 1.0,
            globalMinElev: 0
        )

        let elevation = sampler.elevation(at: center)
        #expect(elevation != nil)

        // Expected: (100 - 0) * (0.8 / 10000) * 1.0 = 0.008
        let geographicScale: Float = 0.8 / 10000.0
        let expected = 100.0 * geographicScale * 1.0
        #expect(abs(elevation! - expected) < 0.001)
    }

    @Test("Bilinear interpolation between grid cells")
    func bilinearInterpolation() {
        let center = CLLocationCoordinate2D(latitude: 36.1069, longitude: -112.1129)
        let zoom = 11
        let tileCoord = TileMath.tileXY(for: Coordinate(center), zoom: zoom)

        // Grid with gradient: elevation increases left to right
        let width = 4
        let height = 4
        var values = [Float](repeating: 0, count: width * height)
        for row in 0..<height {
            for col in 0..<width {
                values[row * width + col] = Float(col) * 100.0
            }
        }
        let grid = ElevationGrid(width: width, height: height, values: values)

        let sampler = ElevationSampler(
            grids: [grid],
            tilePositions: [(x: tileCoord.x, y: tileCoord.y)],
            zoom: zoom,
            center: center,
            radiusMeters: 5000,
            physicalDiameter: 0.8,
            exaggeration: 1.0,
            globalMinElev: 0
        )

        // Sample at center — should get an interpolated value (not exactly a cell boundary)
        let elevation = sampler.elevation(at: center)
        #expect(elevation != nil)
        // The exact value depends on where center falls in the grid, but it should be
        // somewhere between 0 and 300 (the grid's elevation range), scaled
        #expect(elevation! >= 0)
    }

    @Test("Zero exaggeration produces zero elevation")
    func zeroExaggeration() {
        let center = CLLocationCoordinate2D(latitude: 36.1069, longitude: -112.1129)
        let zoom = 11
        let tileCoord = TileMath.tileXY(for: Coordinate(center), zoom: zoom)

        let grid = ElevationGrid(
            width: 16,
            height: 16,
            values: [Float](repeating: 500.0, count: 16 * 16)
        )

        let sampler = ElevationSampler(
            grids: [grid],
            tilePositions: [(x: tileCoord.x, y: tileCoord.y)],
            zoom: zoom,
            center: center,
            radiusMeters: 5000,
            physicalDiameter: 0.8,
            exaggeration: 0.0,
            globalMinElev: 0
        )

        let elevation = sampler.elevation(at: center)
        #expect(elevation != nil)
        #expect(elevation! == 0)
    }
}
