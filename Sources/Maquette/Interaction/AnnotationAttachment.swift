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

/// Places geographic coordinates on the diorama for the content that annotates it.
///
/// A thin façade over a ``DioramaProjection``: the projection answers where a coordinate is, and
/// this decides whether that place is on the model. Keeping the two apart matters because a line
/// crossing the outline needs positions for the vertices that fall outside it, while a pin that
/// lands outside is simply not drawn.
public struct DioramaProxy: Sendable {
    let configuration: DioramaConfiguration
    let physicalDiameter: Float

    /// The mapping the diorama's own geometry was built with.
    public let projection: any DioramaProjection

    /// Creates a proxy for coordinate conversion.
    ///
    /// - Parameters:
    ///   - configuration: The diorama configuration.
    ///   - projection: The mapping the loaded diorama uses. Passing `nil` — which is what content
    ///     applied before anything has loaded gets — falls back to an ``EllipsoidProjection`` built
    ///     from the configuration alone. That is the same frame the photorealistic path uses and
    ///     needs nothing but a centre and a scale, so it is a correct horizontal answer rather than
    ///     a placeholder; only the height is unknown, and it resolves to the datum.
    public init(configuration: DioramaConfiguration, projection: (any DioramaProjection)? = nil) {
        self.configuration = configuration
        self.physicalDiameter = configuration.physicalDiameter
        self.projection = projection ?? EllipsoidProjection(
            center: configuration.center,
            radiusMeters: configuration.radiusMeters,
            physicalDiameter: configuration.physicalDiameter
        )
    }

    /// Converts a geographic coordinate to a 3D position in the diorama's local coordinate space.
    ///
    /// - Returns: A position relative to the diorama centre, or `nil` when the coordinate falls
    ///   outside the chunk's outline or on ground the diorama does not hold.
    public func position(for coordinate: CLLocationCoordinate2D) -> SIMD3<Float>? {
        guard let position = projection.position(for: Coordinate(coordinate)) else { return nil }
        // Culled against the outline rather than a circle around it. The old test — distance from
        // the centre against half the diameter — is only the same question for a round chunk, and
        // clipped the corners off every square one.
        guard configuration.boundary.contains(SIMD2(position.x, position.z)) else { return nil }
        return position
    }

    /// Where a coordinate falls on the diorama's horizontal plane, outline or no outline.
    ///
    /// Always defined. Use this when a place beyond the chunk still has to have a position — the
    /// far end of a route that leaves the model, for instance.
    public func point(for coordinate: CLLocationCoordinate2D) -> SIMD2<Float> {
        projection.point(for: Coordinate(coordinate))
    }
}
