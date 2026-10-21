import Foundation
import simd

/// The one placement contract shared by projected labels and spatial attachments.
enum DioramaAnnotationPlacement {
    static func position(for feature: DioramaFeature, projection: any DioramaProjection,
                         configuration: DioramaConfiguration) -> SIMD3<Float>? {
        guard let descriptor = feature.viewAnnotation, descriptor.isValid else { return nil }
        var coordinate = descriptor.coordinate
        if let terrain = projection as? TerrainProjection {
            guard abs(coordinate.latitude) <= 85.0511287798066 else { return nil }
            let reference = terrain.anchor.coordinate(forDioramaX: Double(terrain.panOffset.x), z: Double(terrain.panOffset.y)).longitude
            coordinate.longitude = reference + (coordinate.longitude - reference).remainder(dividingBy: 360)
        }
        let horizontal = projection.point(for: coordinate)
        guard configuration.boundary.contains(horizontal),
              var point = projection.position(for: coordinate, altitude: feature.style.altitude),
              point.x.isFinite, point.y.isFinite, point.z.isFinite else { return nil }
        // Separation is visual, independent of geographic elevation exaggeration and zoom.
        point.y += configuration.physicalSize * 0.002
        return point
    }
}
