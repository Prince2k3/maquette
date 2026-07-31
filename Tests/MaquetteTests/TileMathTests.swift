import Testing
@testable import Maquette

@Suite("Tile Math Tests")
struct TileMathTests {
    // MARK: - Coordinate to Tile

    @Test("Known tile coordinate for NYC at zoom 14")
    func nycTileAtZoom14() {
        let nyc = Coordinate(latitude: 40.7128, longitude: -74.0060)
        let tile = TileMath.tileXY(for: nyc, zoom: 14)
        // Verified reference values for NYC at zoom 14
        #expect(tile.x == 4823)
        #expect(tile.y == 6160)
    }

    @Test("Tile at zoom 0 is always (0, 0)")
    func zoomZero() {
        let coord = Coordinate(latitude: 40.7128, longitude: -74.0060)
        let tile = TileMath.tileXY(for: coord, zoom: 0)
        #expect(tile.x == 0)
        #expect(tile.y == 0)
    }

    @Test("Equator, prime meridian at zoom 1")
    func equatorPrimeMeridian() {
        let coord = Coordinate(latitude: 0.0, longitude: 0.0)
        let tile = TileMath.tileXY(for: coord, zoom: 1)
        #expect(tile.x == 1)
        #expect(tile.y == 1)
    }

    // MARK: - Tile Bounds

    @Test("Tile bounds at zoom 0 covers entire world")
    func tileBoundsZoom0() {
        let bounds = TileMath.tileBounds(x: 0, y: 0, zoom: 0)
        #expect(abs(bounds.minLongitude - (-180.0)) < 0.01)
        #expect(abs(bounds.maxLongitude - 180.0) < 0.01)
        #expect(bounds.maxLatitude > 85.0)
        #expect(bounds.minLatitude < -85.0)
    }

    @Test("Tile bounds longitude range is correct")
    func tileBoundsLongitudeRange() {
        let bounds = TileMath.tileBounds(x: 0, y: 0, zoom: 1)
        #expect(abs(bounds.minLongitude - (-180.0)) < 0.01)
        #expect(abs(bounds.maxLongitude - 0.0) < 0.01)
    }

    // MARK: - Tiles in Region

    @Test("Single tile for small radius at high zoom")
    func singleTileSmallRadius() {
        let center = Coordinate(latitude: 40.7128, longitude: -74.0060)
        let tiles = TileMath.tilesInRegion(center: center, radiusMeters: 50, zoom: 16)
        #expect(tiles.count >= 1)
    }

    @Test("Multiple tiles for larger radius")
    func multipleTilesLargerRadius() {
        let center = Coordinate(latitude: 40.7128, longitude: -74.0060)
        let tiles = TileMath.tilesInRegion(center: center, radiusMeters: 5000, zoom: 14)
        #expect(tiles.count > 1)
    }

    @Test("Tiles in region always form a rectangular grid")
    func tilesFormGrid() {
        let center = Coordinate(latitude: 48.8566, longitude: 2.3522)
        let tiles = TileMath.tilesInRegion(center: center, radiusMeters: 2000, zoom: 14)

        let xs = Set(tiles.map(\.x))
        let ys = Set(tiles.map(\.y))
        #expect(tiles.count == xs.count * ys.count)
    }

    // MARK: - The Antimeridian

    @Test("A region straddling the date line counts east past it")
    func regionCrossingTheDateLineKeepsCounting() {
        // Longitudes come back folded into -180..<180, so the eastern edge of this region reports a
        // *smaller* longitude than its western edge — and a column range built from the two runs
        // backwards. This is the one the globe found: relocating onto the North Pacific at 179.96°
        // trapped on `Range requires lowerBound <= upperBound` before a single tile was fetched.
        let center = Coordinate(latitude: 36.0544, longitude: 179.9583)
        let zoom = 4
        let tiles = TileMath.tilesInRegion(center: center, radiusMeters: 1_280_000, zoom: zoom)

        #expect(!tiles.isEmpty)

        // Still a rectangle — the window is what fixes the mosaic's origin and the anchor's scale.
        let xs = Set(tiles.map(\.x))
        let ys = Set(tiles.map(\.y))
        #expect(tiles.count == xs.count * ys.count)

        // And it spans the date line rather than folding at it: the columns run contiguously through
        // the world's last one. Folded instead, this window would read as spanning the whole world.
        let count = TileMath.tileCount(atZoom: zoom)
        let sorted = xs.sorted()
        #expect(zip(sorted, sorted.dropFirst()).allSatisfy { $1 == $0 + 1 })
        #expect(sorted.contains(count - 1))
        #expect(sorted.last! >= count)
    }

    @Test("Unwrapped columns fold back to real tiles at the request")
    func everyColumnNamesATileAProviderHas() {
        let center = Coordinate(latitude: 36.0544, longitude: 179.9583)
        let zoom = 4
        let count = TileMath.tileCount(atZoom: zoom)

        for tile in TileMath.tilesInRegion(center: center, radiusMeters: 1_280_000, zoom: zoom) {
            let column = TileMath.wrappedColumn(tile.x, zoom: zoom)
            #expect(column >= 0 && column < count)
        }

        // The fold is a cylinder, not a clamp — a column a whole world either side names the same
        // ground, which is what lets a window keep counting in either direction.
        #expect(TileMath.wrappedColumn(count, zoom: zoom) == 0)
        #expect(TileMath.wrappedColumn(-1, zoom: zoom) == count - 1)
        #expect(TileMath.wrappedColumn(-count - 3, zoom: zoom) == count - 3)
    }

    @Test("A radius wider than the world is answered rather than trapped")
    func aRegionWiderThanTheWorldDoesNotLoop() {
        // Nothing in the library asks for this — a radius this large necessarily carries the northern
        // edge over the pole and back down the far side, which is not a region anyone means. But the
        // answer to a nonsensical radius is a rectangle, not a crash, and the columns still stop at
        // one turn: asking for a column twice fetches the same ground twice and never closes the loop.
        let center = Coordinate(latitude: 0, longitude: 0)
        let zoom = 2
        let tiles = TileMath.tilesInRegion(center: center, radiusMeters: 30_000_000, zoom: zoom)
        #expect(!tiles.isEmpty)
        #expect(Set(tiles.map(\.x)).count <= TileMath.tileCount(atZoom: zoom))
    }

    // MARK: - Meters Per Pixel

    @Test("Meters per pixel decreases with higher zoom")
    func mppDecreasesWithZoom() {
        let mpp10 = TileMath.metersPerPixel(latitude: 40.0, zoom: 10)
        let mpp15 = TileMath.metersPerPixel(latitude: 40.0, zoom: 15)
        #expect(mpp10 > mpp15)
    }

    @Test("Meters per pixel is lower near poles")
    func mppNearPoles() {
        let mppEquator = TileMath.metersPerPixel(latitude: 0.0, zoom: 10)
        let mppHigh = TileMath.metersPerPixel(latitude: 60.0, zoom: 10)
        #expect(mppEquator > mppHigh)
    }

    // MARK: - Optimal Zoom Level

    @Test("Optimal zoom for city-scale radius")
    func optimalZoomCityScale() {
        let zoom = TileMath.optimalZoomLevel(radiusMeters: 5000, latitude: 40.0)
        #expect(zoom >= 10 && zoom <= 16)
    }

    @Test("Larger radius yields lower zoom")
    func largerRadiusLowerZoom() {
        let zoomSmall = TileMath.optimalZoomLevel(radiusMeters: 500, latitude: 40.0)
        let zoomLarge = TileMath.optimalZoomLevel(radiusMeters: 50000, latitude: 40.0)
        #expect(zoomSmall > zoomLarge)
    }

    // MARK: - Round Trip

    @Test("Coordinate to tile and back contains original coordinate")
    func roundTrip() {
        let original = Coordinate(latitude: 40.7128, longitude: -74.0060)
        let zoom = 14
        let tile = TileMath.tileXY(for: original, zoom: zoom)
        let bounds = TileMath.tileBounds(x: tile.x, y: tile.y, zoom: zoom)

        #expect(original.latitude >= bounds.minLatitude)
        #expect(original.latitude <= bounds.maxLatitude)
        #expect(original.longitude >= bounds.minLongitude)
        #expect(original.longitude <= bounds.maxLongitude)
    }
}
