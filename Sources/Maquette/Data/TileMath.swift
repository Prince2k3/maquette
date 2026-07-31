import Foundation

/// Tile coordinate pair.
public struct TileCoordinate: Sendable, Hashable {
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// Geographic bounding box in degrees.
public struct TileBounds: Sendable {
    public let minLatitude: Double
    public let minLongitude: Double
    public let maxLatitude: Double
    public let maxLongitude: Double
}

/// Standard Web Mercator (EPSG:3857) slippy-map tile math.
public enum TileMath {
    /// Converts a geographic coordinate to tile x/y at the given zoom level.
    public static func tileXY(for coordinate: Coordinate, zoom: Int) -> TileCoordinate {
        let n = pow(2.0, Double(zoom))
        let latRad = coordinate.latitudeRadians

        let x = Int(floor((coordinate.longitude + 180.0) / 360.0 * n))
        let y = Int(floor((1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / .pi) / 2.0 * n))

        let maxTile = Int(n) - 1
        return TileCoordinate(
            x: min(max(x, 0), maxTile),
            y: min(max(y, 0), maxTile)
        )
    }

    /// Converts a geographic coordinate to a *fractional* tile coordinate at the given zoom.
    ///
    /// Unlike `tileXY(for:zoom:)` this does not floor, so the fractional part is the position
    /// within the tile. Web Mercator is linear in this space, which is what makes a diorama's
    /// ground mapping a scale and a translation rather than a projection per sample.
    public static func tilePoint(for coordinate: Coordinate, zoom: Int) -> SIMD2<Double> {
        let n = pow(2.0, Double(zoom))
        let latRad = coordinate.latitudeRadians
        return SIMD2(
            (coordinate.longitude + 180.0) / 360.0 * n,
            (1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / .pi) / 2.0 * n
        )
    }

    /// Converts a fractional tile coordinate back to a geographic coordinate.
    public static func coordinate(forTilePoint tile: SIMD2<Double>, zoom: Int) -> Coordinate {
        let n = pow(2.0, Double(zoom))
        let longitude = tile.x / n * 360.0 - 180.0
        let latitude = atan(sinh(.pi * (1.0 - 2.0 * tile.y / n))) * 180.0 / .pi
        return Coordinate(latitude: latitude, longitude: longitude)
    }

    /// Ground distance spanned by one whole tile at a given latitude and zoom level.
    public static func metersPerTile(latitude: Double, zoom: Int) -> Double {
        let latRad = latitude * .pi / 180.0
        return 40_075_016.686 * cos(latRad) / pow(2.0, Double(zoom))
    }

    /// Returns the geographic bounding box of a tile.
    public static func tileBounds(x: Int, y: Int, zoom: Int) -> TileBounds {
        let n = pow(2.0, Double(zoom))

        let minLon = Double(x) / n * 360.0 - 180.0
        let maxLon = Double(x + 1) / n * 360.0 - 180.0

        let maxLat = atan(sinh(.pi * (1.0 - 2.0 * Double(y) / n))) * 180.0 / .pi
        let minLat = atan(sinh(.pi * (1.0 - 2.0 * Double(y + 1) / n))) * 180.0 / .pi

        return TileBounds(
            minLatitude: minLat,
            minLongitude: minLon,
            maxLatitude: maxLat,
            maxLongitude: maxLon
        )
    }

    /// How many tiles span the world on each axis at a given zoom.
    public static func tileCount(atZoom zoom: Int) -> Int {
        guard zoom >= 0, zoom < 31 else { return 0 }
        return 1 << zoom
    }

    /// Folds a column into the range a provider will accept.
    ///
    /// **Columns wrap and rows do not**, because the world is a cylinder: counting east past the
    /// antimeridian keeps naming real ground, while counting north past the pole names none. This is
    /// the fold every request has to go through, and the counterpart to the convention
    /// ``tilesInRegion(center:radiusMeters:zoom:)`` and ``TerrainRoller`` both keep — a *window* is
    /// left unwrapped so it stays a rectangle, and only the request reaching a provider is folded.
    public static func wrappedColumn(_ x: Int, zoom: Int) -> Int {
        let count = tileCount(atZoom: zoom)
        guard count > 0 else { return x }
        return ((x % count) + count) % count
    }

    /// Returns all tile coordinates that intersect the circular region defined by center and radius.
    ///
    /// **Columns are returned unwrapped**, so a region straddling the antimeridian counts east past
    /// it — `x` may reach or exceed ``tileCount(atZoom:)`` and callers fold it with
    /// ``wrappedColumn(_:zoom:)`` when they ask a provider for the tile. The window has to stay a
    /// rectangle: it is what fixes the mosaic's origin and the ``TerrainAnchor``'s scale, and a
    /// window whose columns wrapped would read as spanning the whole world rather than a few tiles
    /// either side of the date line. Same convention ``TerrainRoller`` keeps, for the same reason.
    ///
    /// Getting this wrong is not a distortion but a crash: longitudes come back folded into
    /// `-180..<180`, so the eastern edge of a region centred at 179.96° lands *west* of its own
    /// western edge and the column range runs backwards.
    public static func tilesInRegion(
        center: Coordinate,
        radiusMeters: Double,
        zoom: Int
    ) -> [TileCoordinate] {
        // Compute bounding box corners
        let north = Turf.destination(from: center, meters: radiusMeters, bearing: 0)
        let south = Turf.destination(from: center, meters: radiusMeters, bearing: 180)
        let east = Turf.destination(from: center, meters: radiusMeters, bearing: 90)
        let west = Turf.destination(from: center, meters: radiusMeters, bearing: 270)

        let topLeft = Coordinate(latitude: north.latitude, longitude: west.longitude)
        let bottomRight = Coordinate(latitude: south.latitude, longitude: east.longitude)

        let tl = tileXY(for: topLeft, zoom: zoom)
        let br = tileXY(for: bottomRight, zoom: zoom)

        let count = tileCount(atZoom: zoom)
        // The east edge lands west of the west edge exactly when the region crosses the date line,
        // so keep counting rather than folding. A region wider than the world stops at one turn:
        // asking for a column twice fetches the same ground twice and never closes the loop.
        var lastColumn = br.x < tl.x ? br.x + count : br.x
        if count > 0 {
            lastColumn = min(lastColumn, tl.x + count - 1)
        }

        // Rows are taken in index order rather than corner order. A radius large enough to carry the
        // northern edge over the pole brings it back down the far side *below* the southern one, and
        // however little sense that region makes, the answer to it is a rectangle rather than a trap.
        let firstRow = min(tl.y, br.y)
        let lastRow = max(tl.y, br.y)

        var tiles: [TileCoordinate] = []
        for ty in firstRow...lastRow {
            for tx in tl.x...lastColumn {
                tiles.append(TileCoordinate(x: tx, y: ty))
            }
        }
        return tiles
    }

    /// Meters per pixel at a given latitude and zoom level.
    public static func metersPerPixel(latitude: Double, zoom: Int) -> Double {
        let latRad = latitude * .pi / 180.0
        return 156543.03392 * cos(latRad) / pow(2.0, Double(zoom))
    }

    /// Calculates the optimal zoom level for a given radius and latitude.
    ///
    /// Targets approximately 256–512 pixels across the diorama diameter for good mesh resolution.
    public static func optimalZoomLevel(radiusMeters: Double, latitude: Double) -> Int {
        let diameterMeters = radiusMeters * 2.0
        let targetPixels = 512.0

        for z in stride(from: 18, through: 1, by: -1) {
            let mpp = metersPerPixel(latitude: latitude, zoom: z)
            let pixels = diameterMeters / mpp
            if pixels <= targetPixels {
                return z
            }
        }
        return 1
    }
}
