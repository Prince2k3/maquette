import CoreLocation
import Foundation
import SwiftUI

/// Proxy provided to annotation builder closures, allowing annotation views to be positioned at geographic coordinates.
public struct DioramaProxy {
    let configuration: DioramaConfiguration
    let physicalDiameter: Float

    /// Storage for annotations added via the builder.
    var annotations: [AnnotationItem] = []

    /// Represents a single annotation to be displayed on the diorama.
    public struct AnnotationItem: Identifiable {
        public let id: String
        public let coordinate: CLLocationCoordinate2D
        public let title: String
        public let content: AnyView
    }

    /// Adds an annotation at the given coordinate.
    ///
    /// - Parameters:
    ///   - coordinate: Geographic location of the annotation.
    ///   - title: Display title.
    ///   - content: SwiftUI view to display as the annotation label.
    public mutating func annotation<Content: View>(
        coordinate: CLLocationCoordinate2D,
        title: String,
        @ViewBuilder content: () -> Content
    ) {
        let item = AnnotationItem(
            id: title,
            coordinate: coordinate,
            title: title,
            content: AnyView(content())
        )
        annotations.append(item)
    }

    /// Converts a geographic coordinate to a 3D position in the diorama's local coordinate space.
    ///
    /// - Parameter coordinate: The geographic coordinate to project.
    /// - Returns: A 3D position relative to the diorama center, or `nil` if outside bounds.
    public func position(for coordinate: CLLocationCoordinate2D) -> SIMD3<Float>? {
        let center = Coordinate(configuration.center)
        let point = Coordinate(coordinate)

        let earthRadius = 6_371_000.0
        let latDiff = (point.latitude - center.latitude) * .pi / 180.0
        let lonDiff = (point.longitude - center.longitude) * .pi / 180.0

        let northMeters = latDiff * earthRadius
        let eastMeters = lonDiff * earthRadius * cos(center.latitudeRadians)

        let scale = Double(physicalDiameter) / (configuration.radiusMeters * 2.0)
        let x = Float(eastMeters * scale)
        let z = Float(-northMeters * scale) // Negate because north is -Z in RealityKit

        // Check if within bounds
        let dist = sqrt(x * x + z * z)
        guard dist <= physicalDiameter / 2.0 else { return nil }

        return SIMD3<Float>(x, 0, z)
    }
}
