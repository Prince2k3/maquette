import CoreLocation
import Foundation
import SwiftUI

// MARK: - Content Protocol

/// Protocol for content that can be placed on a diorama.
public protocol DioramaContent {
    /// The concrete content items this value produces.
    var items: [DioramaContentItem] { get }
}

/// A concrete content item — either an annotation or a route preview.
///
/// Annotations used to come in one case per shape, `marker` and `polyline`, which meant the shape a
/// caller could draw was fixed by this enum: handing in a `.geojson` file meant unpacking it into
/// whichever of the two it happened to resemble, and anything else had nowhere to go. An annotation
/// is now a ``Feature`` plus a style, so what gets drawn is a property of the data.
public enum DioramaContentItem: Sendable {
    case annotation(DioramaAnnotation)
    case routePreview(DioramaRoutePreview)
}

// MARK: - Annotation

/// A GeoJSON feature drawn on the diorama.
///
/// ```swift
/// DioramaAnnotation.marker(
///     at: Coordinate(latitude: 36.1069, longitude: -112.1129),
///     title: "Grand Canyon"
/// )
/// ```
///
/// The feature is the same value that came out of the data, unmodified — a point becomes a pin, a
/// line becomes a ribbon, and a multi-geometry becomes one of each part. The style says how it
/// looks and, through ``AnnotationStyle/altitude``, what any altitude on its positions means.
///
/// ```swift
/// let collection = try JSONDecoder().decode(FeatureCollection.self, from: data)
/// DioramaView(configuration: config) {
///     for feature in collection.features {
///         DioramaAnnotation(feature)
///     }
/// }
/// ```
public struct DioramaAnnotation: DioramaContent, Sendable, Identifiable {
    /// Identity for the entity this becomes, so re-applying content replaces rather than duplicates.
    ///
    /// Taken from the feature's own `id` when it has one — GeoJSON carries identity and a caller's
    /// data should keep it — and generated otherwise.
    public let id: String
    /// The feature to draw.
    public var feature: Feature
    /// How to draw it.
    public var style: AnnotationStyle

    /// Creates an annotation from a feature.
    ///
    /// - Parameters:
    ///   - feature: The geometry and properties to draw.
    ///   - style: How it is drawn. Defaults to a red pin and a blue ribbon.
    ///   - id: Identity for the resulting entity. Defaults to the feature's own, or a fresh UUID.
    public init(_ feature: Feature, style: AnnotationStyle = AnnotationStyle(), id: String? = nil) {
        self.feature = feature
        self.style = style
        self.id = id ?? Self.identifier(for: feature)
    }

    private static func identifier(for feature: Feature) -> String {
        switch feature.id {
        case .string(let value): value
        case .number(let value): String(value)
        case nil: UUID().uuidString
        }
    }

    public var items: [DioramaContentItem] { [.annotation(self)] }
}

// MARK: - Convenience

extension DioramaAnnotation {
    /// A pin at a coordinate.
    ///
    /// - Parameters:
    ///   - coordinate: Where the pin goes.
    ///   - tint: Colour of the pin. Defaults to `.red`.
    ///   - altitude: What any altitude on the coordinate means. Defaults to sitting on the ground.
    ///   - title: Identity for the pin, and the `title` property on the feature it makes.
    public static func marker(
        at coordinate: Coordinate,
        tint: Color = .red,
        altitude: AltitudeReference = .clampToGround,
        title: String = UUID().uuidString
    ) -> DioramaAnnotation {
        DioramaAnnotation(
            Feature.point(coordinate, id: .string(title), properties: ["title": .string(title)]),
            style: AnnotationStyle(tint: tint, altitude: altitude),
            id: title
        )
    }

    /// A pin at a CoreLocation coordinate.
    public static func marker(
        at coordinate: CLLocationCoordinate2D,
        tint: Color = .red,
        altitude: AltitudeReference = .clampToGround,
        title: String = UUID().uuidString
    ) -> DioramaAnnotation {
        marker(at: Coordinate(coordinate), tint: tint, altitude: altitude, title: title)
    }

    /// A ribbon following a run of coordinates.
    ///
    /// - Parameters:
    ///   - coordinates: The path, in order.
    ///   - tint: Colour of the ribbon. Defaults to `.blue`.
    ///   - lineWidth: Width in diorama metres. Defaults to `0.003`.
    ///   - altitude: What any altitude on the coordinates means. Defaults to following the ground.
    ///   - id: Identity for the ribbon.
    public static func line(
        through coordinates: [Coordinate],
        tint: Color = .blue,
        lineWidth: Float = 0.003,
        altitude: AltitudeReference = .clampToGround,
        id: String = UUID().uuidString
    ) -> DioramaAnnotation {
        DioramaAnnotation(
            Feature.line(coordinates, id: .string(id)),
            style: AnnotationStyle(tint: tint, lineWidth: lineWidth, altitude: altitude),
            id: id
        )
    }

    /// A ribbon following a run of CoreLocation coordinates.
    public static func line(
        through coordinates: [CLLocationCoordinate2D],
        tint: Color = .blue,
        lineWidth: Float = 0.003,
        altitude: AltitudeReference = .clampToGround,
        id: String = UUID().uuidString
    ) -> DioramaAnnotation {
        line(
            through: coordinates.map { Coordinate($0) },
            tint: tint,
            lineWidth: lineWidth,
            altitude: altitude,
            id: id
        )
    }
}

// MARK: - Style

/// How an annotation is drawn.
///
/// One style for every geometry rather than one type per shape: a feature collection routinely mixes
/// points and lines under a single visual treatment, and splitting the style by shape would make the
/// caller sort its own data before styling it. Fields that do not apply to a geometry are simply
/// unused — `lineWidth` means nothing to a pin.
public struct AnnotationStyle: Sendable {
    /// Colour of the pin, or of the ribbon.
    public var tint: Color
    /// Width of a ribbon, in diorama metres.
    public var lineWidth: Float
    /// What an altitude carried on the feature's positions means.
    public var altitude: AltitudeReference

    public init(
        tint: Color = .red,
        lineWidth: Float = 0.003,
        altitude: AltitudeReference = .clampToGround
    ) {
        self.tint = tint
        self.lineWidth = lineWidth
        self.altitude = altitude
    }
}

// MARK: - Content Group

/// Collects multiple `DioramaContent` values into a flat array. Produced by `DioramaContentBuilder`.
public struct DioramaContentGroup: DioramaContent, Sendable {
    public let items: [DioramaContentItem]

    public init(items: [DioramaContentItem]) {
        self.items = items
    }
}

extension FeatureCollection: DioramaContent {
    /// Draws every feature in the collection with the default style.
    ///
    /// The whole point of speaking GeoJSON: a decoded document is content, with nothing in between.
    public var items: [DioramaContentItem] {
        features.map { .annotation(DioramaAnnotation($0)) }
    }
}

// MARK: - Result Builder

/// Result builder for declaring diorama content in a SwiftUI-like syntax.
///
/// ```swift
/// DioramaView(configuration: config) {
///     DioramaAnnotation.marker(at: coord1, title: "A")
///     DioramaAnnotation.line(through: [coord1, coord2])
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
        position(for: Coordinate(coordinate))
    }

    /// Converts a coordinate to a 3D position, honouring any altitude it carries.
    public func position(
        for coordinate: Coordinate,
        altitude: AltitudeReference = .clampToGround
    ) -> SIMD3<Float>? {
        guard let position = projection.position(for: coordinate, altitude: altitude) else {
            return nil
        }
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
