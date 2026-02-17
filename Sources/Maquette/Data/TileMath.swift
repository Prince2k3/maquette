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

    /// Returns all tile coordinates that intersect the circular region defined by center and radius.
    public static func tilesInRegion(
        center: Coordinate,
        radiusMeters: Double,
        zoom: Int
    ) -> [TileCoordinate] {
        // Compute bounding box corners
        let north = center.offset(northMeters: radiusMeters, eastMeters: 0)
        let south = center.offset(northMeters: -radiusMeters, eastMeters: 0)
        let east = center.offset(northMeters: 0, eastMeters: radiusMeters)
        let west = center.offset(northMeters: 0, eastMeters: -radiusMeters)

        let topLeft = Coordinate(latitude: north.latitude, longitude: west.longitude)
        let bottomRight = Coordinate(latitude: south.latitude, longitude: east.longitude)

        let tl = tileXY(for: topLeft, zoom: zoom)
        let br = tileXY(for: bottomRight, zoom: zoom)

        var tiles: [TileCoordinate] = []
        for ty in tl.y...br.y {
            for tx in tl.x...br.x {
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
