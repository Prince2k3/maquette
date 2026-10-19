import Foundation

extension DioramaStore {
    /// Geographic read-back uses the same projection as the drawn ground, including its pan.
    var visibleGroundRegion: DioramaRegion {
        let center: Coordinate
        if let terrain = projection as? TerrainProjection {
            center = terrain.anchor.coordinate(
                forDioramaX: Double(panOffset.x), z: Double(panOffset.y)
            )
        } else if let ellipsoid = projection as? EllipsoidProjection,
                  ellipsoid.geographicScale > 0,
                  let coordinate = ellipsoid.converter.coordinate(atHorizontalPoint:
                    SIMD2(Double(panOffset.x), Double(panOffset.y)) / Double(ellipsoid.geographicScale)
                  ) {
            center = coordinate
        } else {
            center = Coordinate(configuration.center)
        }
        return DioramaRegion(center: center, radius: groundRadiusMeters)
    }
}
