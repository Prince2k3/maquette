import CoreLocation
import Foundation
import SwiftUI

// MARK: - Content Protocol

/// Protocol for content that can be placed on a diorama.
public protocol DioramaContent {
    /// The concrete content items this value produces.
    var items: [DioramaContentItem] { get }
}

/// A concrete content item — either a marker, polyline, or route preview.
public enum DioramaContentItem: Sendable {
    case marker(DioramaMarker)
    case polyline(DioramaPolyline)
    case routePreview(DioramaRoutePreview)
}

// MARK: - Marker

/// A map marker placed at a geographic coordinate on the diorama.
///
/// ```swift
/// DioramaMarker(
///     coordinate: CLLocationCoordinate2D(latitude: 36.1069, longitude: -112.1129),
///     tint: .red,
///     systemImage: "mappin",
///     title: "Grand Canyon"
/// )
/// ```
public struct DioramaMarker: DioramaContent, Sendable {
    /// The geographic coordinate where the marker is placed.
    public let coordinate: CLLocationCoordinate2D
    /// The tint color applied to the marker pin.
    public let tint: Color
    /// The SF Symbol name displayed on the marker head.
    public let systemImage: String
    /// A unique title/identifier for the marker.
    public let title: String

    /// Creates a diorama marker.
    ///
    /// - Parameters:
    ///   - coordinate: Geographic location of the marker.
    ///   - tint: Color of the marker pin. Defaults to `.red`.
    ///   - systemImage: SF Symbol name for the marker head. Defaults to `"mappin"`.
    ///   - title: Display title and identifier for the marker.
    public init(
        coordinate: CLLocationCoordinate2D,
        tint: Color = .red,
        systemImage: String = "mappin",
        title: String = UUID().uuidString
    ) {
        self.coordinate = coordinate
        self.tint = tint
        self.systemImage = systemImage
        self.title = title
    }

    public var items: [DioramaContentItem] { [.marker(self)] }
}

// MARK: - Polyline

/// A polyline connecting geographic coordinates on the diorama surface.
///
/// ```swift
/// DioramaPolyline(
///     coordinates: [coord1, coord2, coord3],
///     color: .blue,
///     lineWidth: 0.003
/// )
/// ```
public struct DioramaPolyline: DioramaContent, Sendable {
    /// Unique identifier for this polyline.
    public let id: String
    /// The geographic coordinates that define the polyline path.
    public let coordinates: [CLLocationCoordinate2D]
    /// The color of the polyline ribbon.
    public let color: Color
    /// The width of the polyline ribbon in diorama-space meters.
    public let lineWidth: Float

    /// Creates a diorama polyline.
    ///
    /// - Parameters:
    ///   - coordinates: Geographic coordinates defining the path.
    ///   - color: Color of the polyline. Defaults to `.blue`.
    ///   - lineWidth: Width in diorama meters. Defaults to `0.003`.
    ///   - id: Unique identifier. Defaults to a generated UUID.
    public init(
        coordinates: [CLLocationCoordinate2D],
        color: Color = .blue,
        lineWidth: Float = 0.003,
        id: String = UUID().uuidString
    ) {
        self.coordinates = coordinates
        self.color = color
        self.lineWidth = lineWidth
        self.id = id
    }

    public var items: [DioramaContentItem] { [.polyline(self)] }
}

// MARK: - Content Group

/// Collects multiple `DioramaContent` values into a flat array. Produced by `DioramaContentBuilder`.
public struct DioramaContentGroup: DioramaContent, Sendable {
    public let items: [DioramaContentItem]

    public init(items: [DioramaContentItem]) {
        self.items = items
    }
}

// MARK: - Result Builder

/// Result builder for declaring diorama content (markers, polylines) in a SwiftUI-like syntax.
///
/// ```swift
/// DioramaView(configuration: config) {
///     DioramaMarker(coordinate: coord1, title: "A")
///     DioramaPolyline(coordinates: [coord1, coord2])
/// }
/// ```
@resultBuilder
public struct DioramaContentBuilder {
    public static func buildBlock(_ components: any DioramaContent...) -> DioramaContentGroup {
        DioramaContentGroup(items: components.flatMap(\.items))
    }

    public static func buildOptional(_ component: (any DioramaContent)?) -> DioramaContentGroup {
        DioramaContentGroup(items: component?.items ?? [])
    }

    public static func buildEither(first component: any DioramaContent) -> DioramaContentGroup {
        DioramaContentGroup(items: component.items)
    }

    public static func buildEither(second component: any DioramaContent) -> DioramaContentGroup {
        DioramaContentGroup(items: component.items)
    }

    public static func buildArray(_ components: [any DioramaContent]) -> DioramaContentGroup {
        DioramaContentGroup(items: components.flatMap(\.items))
    }
}

// MARK: - Proxy

/// Utility for converting geographic coordinates to 3D positions in the diorama's local coordinate space.
public struct DioramaProxy: Sendable {
    let configuration: DioramaConfiguration
    let physicalDiameter: Float
    let elevationSampler: ElevationSampler?

    /// Creates a proxy for coordinate conversion.
    ///
    /// - Parameters:
    ///   - configuration: The diorama configuration.
    ///   - elevationSampler: Optional sampler for terrain height queries.
    public init(configuration: DioramaConfiguration, elevationSampler: ElevationSampler? = nil) {
        self.configuration = configuration
        self.physicalDiameter = configuration.physicalDiameter
        self.elevationSampler = elevationSampler
    }

    /// Converts a geographic coordinate to a 3D position in the diorama's local coordinate space.
    ///
    /// When an `ElevationSampler` is available, uses the exact same tile-grid layout as the terrain
    /// mesh generator so that markers and polylines sit precisely on the terrain surface. Falls back
    /// to a spherical-Earth approximation for photorealistic mode or when no sampler is present.
    ///
    /// - Parameter coordinate: The geographic coordinate to project.
    /// - Returns: A 3D position relative to the diorama center, or `nil` if outside bounds.
    public func position(for coordinate: CLLocationCoordinate2D) -> SIMD3<Float>? {
        // Prefer tile-based positioning when elevation sampler is available — this matches
        // the terrain mesh coordinate system exactly.
        if let sampler = elevationSampler {
            return sampler.position(for: coordinate)
        }

        // Fallback: spherical Earth approximation (used when no terrain tiles are loaded)
        let center = Coordinate(configuration.center)
        let point = Coordinate(coordinate)

        let earthRadius = 6_371_000.0
        let latDiff = (point.latitude - center.latitude) * .pi / 180.0
        let lonDiff = (point.longitude - center.longitude) * .pi / 180.0

        let northMeters = latDiff * earthRadius
        let eastMeters = lonDiff * earthRadius * cos(center.latitudeRadians)

        let scale = Double(physicalDiameter) / (configuration.radiusMeters * 2.0)
        let x = Float(eastMeters * scale)
        let z = Float(-northMeters * scale) // North is -Z in RealityKit

        // Check if within bounds
        let dist = sqrt(x * x + z * z)
        guard dist <= physicalDiameter / 2.0 else { return nil }

        return SIMD3<Float>(x, 0, z)
    }
}
