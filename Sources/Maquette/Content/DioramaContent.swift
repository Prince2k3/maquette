import CoreLocation
import Foundation
import SwiftUI

// MARK: - Content Protocol

/// Protocol for content that can be placed on a diorama.
public protocol DioramaContent {
    /// The content composed by this value. Existing items-only conformers use `Never`.
    associatedtype Body: DioramaContent = Never

    /// Declares reusable content using the same builder as a diorama view.
    @DioramaContentBuilder var body: Body { get }

    /// The concrete content items this value produces.
    var items: [DioramaContentItem] { get }
}

/// A concrete content item — either an annotation or a route preview.
///
/// Annotations used to come in one case per shape, `marker` and `polyline`, which meant the shape a
/// caller could draw was fixed by this enum: handing in a `.geojson` file meant unpacking it into
/// whichever of the two it happened to resemble, and anything else had nowhere to go. An annotation
/// is now a ``Feature`` plus a style, so what gets drawn is a property of the data.
public enum DioramaContentItem: Sendable, Equatable {
    case annotation(DioramaFeature)
    case routePreview(DioramaRoutePreview)
}

// MARK: - Annotation

/// A GeoJSON feature drawn on the diorama.
///
/// ```swift
/// DioramaMarker("Grand Canyon", coordinate: Coordinate(latitude: 36.1069, longitude: -112.1129))
/// ```
///
/// The feature is the same value that came out of the data, unmodified — a point becomes a pin, a
/// line becomes a ribbon, and a multi-geometry becomes one of each part. The style says how it
/// looks and, through ``DioramaFeatureStyle/altitude``, what any altitude on its positions means.
///
/// ```swift
/// let collection = try JSONDecoder().decode(FeatureCollection.self, from: data)
/// DioramaView(region: region) {
///     for feature in collection.features {
///         DioramaFeature(feature)
///     }
/// }
/// ```
public struct DioramaFeature: DioramaContent, Sendable, Equatable, Identifiable {
    /// Identity for the entity this becomes, so re-applying content replaces rather than duplicates.
    ///
    /// Taken from the feature's own `id` when it has one — GeoJSON carries identity and a caller's
    /// data should keep it — and otherwise derived as a stable digest of the feature itself, so
    /// declaring the same content twice produces the same identity rather than a fresh one per
    /// evaluation. Two literally identical anonymous features therefore collide, and harmlessly:
    /// they would render identically anyway.
    public internal(set) var id: String
    var selectionAnnotationID: String? = nil
    var contentIdentity: DioramaContentIdentity?
    var selectionTag: DioramaSelectionTag? = nil
    var contentStyleOverrides: UInt16 = 0
    var overlay: DioramaOverlayPayload?
    var viewAnnotation: DioramaAnnotationDescriptor?
    var viewFactory: DioramaAnnotationViewFactory?

    /// The feature to draw.
    public var feature: Feature
    /// How to draw it.
    public var style: DioramaFeatureStyle

    /// Creates an annotation from a feature.
    ///
    /// - Parameters:
    ///   - feature: The geometry and properties to draw.
    ///   - style: How it is drawn. Defaults to a red pin and a blue ribbon.
    ///   - id: Identity for the resulting entity. Defaults to the feature's own, or a digest.
    public init(_ feature: Feature, style: DioramaFeatureStyle = DioramaFeatureStyle(), id: String? = nil) {
        self.feature = feature
        self.style = style
        self.id = id ?? Self.identifier(for: feature)
    }

    private static func identifier(for feature: Feature) -> String {
        switch feature.id {
        case .string(let value): value
        case .number(let value): String(value)
        case nil: Self.digest(of: feature)
        }
    }

    /// A deterministic identity for a feature that carries none.
    ///
    /// A fresh UUID here — the previous rule — meant every re-evaluation of a content closure
    /// produced all-new identities, which alone forced the scene to tear its overlays down and
    /// rebuild them on every SwiftUI render. A digest of the encoded feature is the same string
    /// every time the same feature is declared, which is what lets a diff say "unchanged".
    private static func digest(of feature: Feature) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(feature) else { return UUID().uuidString }
        // FNV-1a: cheap, deterministic across launches, and collision-tolerant here because two
        // colliding features render identically by construction.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return "feature-\(String(hash, radix: 36))"
    }

    public var items: [DioramaContentItem] { [.annotation(self)] }
}

// MARK: - Marker & Polyline

/// A pin at a coordinate. The parallel of MapKit's `Marker`.
///
/// ```swift
/// DioramaView(region: region) {
///     DioramaMarker("Summit", coordinate: summit, tint: .orange)
/// }
/// ```
public struct DioramaMarker: DioramaContent, Sendable, Equatable {
    /// The annotation this marker reduces to.
    public var annotation: DioramaFeature

    /// Creates a marker.
    ///
    /// - Parameters:
    ///   - title: Stored as the feature's `title` property. Display only — never identity.
    ///   - coordinate: Where the pin goes.
    ///   - tint: Colour of the pin. Defaults to `.red`.
    ///   - altitude: What any altitude on the coordinate means. Defaults to sitting on the ground.
    ///   - id: Explicit identity, or `nil` to derive a stable one from the feature.
    public init(
        _ title: String = "",
        coordinate: Coordinate,
        tint: Color = .red,
        altitude: AltitudeReference = .clampToGround,
        id: String? = nil
    ) {
        let properties: [String: JSONValue] = title.isEmpty ? [:] : ["title": .string(title)]
        self.annotation = DioramaFeature(
            Feature.point(coordinate, id: id.map { .string($0) }, properties: properties),
            style: DioramaFeatureStyle(tint: tint, altitude: altitude),
            id: id
        )
    }

    /// Creates a marker at a CoreLocation coordinate.
    public init(
        _ title: String = "",
        coordinate: CLLocationCoordinate2D,
        tint: Color = .red,
        altitude: AltitudeReference = .clampToGround,
        id: String? = nil
    ) {
        self.init(title, coordinate: Coordinate(coordinate), tint: tint, altitude: altitude, id: id)
    }

    public var items: [DioramaContentItem] { annotation.items }
}

/// A ribbon following a run of coordinates. The parallel of MapKit's `MapPolyline`.
///
/// A ribbon drops the vertices the diorama has no ground for, which welds the line across the gap
/// rather than breaking it in two — right for a line clipping the outline's corner, wrong for one
/// that leaves the chunk and comes back.
public struct DioramaPolyline: DioramaContent, Sendable, Equatable {
    /// The annotation this polyline reduces to.
    public var annotation: DioramaFeature

    /// Creates a polyline.
    ///
    /// - Parameters:
    ///   - coordinates: The path, in order.
    ///   - tint: Colour of the ribbon. Defaults to `.blue`.
    ///   - lineWidth: Width in diorama metres. Defaults to `0.003`.
    ///   - altitude: What any altitude on the coordinates means. Defaults to following the ground.
    ///   - id: Explicit identity, or `nil` to derive a stable one from the feature.
    public init(
        coordinates: [Coordinate],
        tint: Color = .blue,
        lineWidth: Float = 0.003,
        altitude: AltitudeReference = .clampToGround,
        id: String? = nil
    ) {
        self.annotation = DioramaFeature(
            Feature.line(coordinates, id: id.map { .string($0) }),
            style: DioramaFeatureStyle(tint: tint, lineWidth: lineWidth, altitude: altitude),
            id: id
        )
    }

    /// Creates a polyline through CoreLocation coordinates.
    public init(
        coordinates: [CLLocationCoordinate2D],
        tint: Color = .blue,
        lineWidth: Float = 0.003,
        altitude: AltitudeReference = .clampToGround,
        id: String? = nil
    ) {
        self.init(
            coordinates: coordinates.map { Coordinate($0) },
            tint: tint,
            lineWidth: lineWidth,
            altitude: altitude,
            id: id
        )
    }

    public var items: [DioramaContentItem] { annotation.items }
}

// MARK: - Style

/// How an annotation is drawn.
///
/// One style for every geometry rather than one type per shape: a feature collection routinely mixes
/// points and lines under a single visual treatment, and splitting the style by shape would make the
/// caller sort its own data before styling it. Fields that do not apply to a geometry are simply
/// unused — `lineWidth` means nothing to a pin.
public struct DioramaFeatureStyle: Sendable, Equatable {
    /// Colour of the pin, or of the ribbon.
    public var tint: Color
    /// Width of a ribbon, in diorama metres.
    public var lineWidth: Float {
        get { if case .physicalMeters(let value) = strokeStyle.width { value } else { 0 } }
        set { strokeStyle.width = .physicalMeters(newValue) }
    }
    /// Independent area fill and outline. A nil stroke uses the tint on lines and no outline on areas.
    /// Area fill color, independent of the outline.
    public var fill: Color = .blue.opacity(0.2)
    /// Optional area outline color. Lines fall back to tint.
    public var stroke: Color?
    /// Width, endpoint, join, and dash settings.
    public var strokeStyle: DioramaStrokeStyle
    /// Multiplies the fill/stroke/image alpha without changing their colors.
    /// Overall content opacity.
    public var opacity: Double = 1
    /// What an altitude carried on the feature's positions means.
    public var altitude: AltitudeReference

    public init(
        tint: Color = .red,
        lineWidth: Float = 0.003,
        altitude: AltitudeReference = .clampToGround
    ) {
        self.tint = tint
        self.strokeStyle = DioramaStrokeStyle(width: .physicalMeters(lineWidth))
        self.altitude = altitude
    }
}

// MARK: - Content Group

/// Collects multiple `DioramaContent` values into a flat array. Produced by `DioramaContentBuilder`.
public struct DioramaContentGroup: DioramaContent, Sendable, Equatable {
    public let items: [DioramaContentItem]

    /// The group with nothing in it — what a `DioramaView` with no content closure shows.
    public static let empty = DioramaContentGroup(items: [])

    /// Creates a group from a reusable content declaration.
    public init(@DioramaContentBuilder content: () -> DioramaContentGroup) {
        self = content()
    }

    /// Creates a group from already flattened renderer items.
    public init(items: [DioramaContentItem]) {
        self.items = items
    }
}

extension FeatureCollection: DioramaContent {
    /// Draws every feature in the collection with the default style.
    ///
    /// The whole point of speaking GeoJSON: a decoded document is content, with nothing in between.
    public var items: [DioramaContentItem] {
        features.map { .annotation(DioramaFeature($0)) }
    }
}

// MARK: - Result Builder

/// Result builder for declaring diorama content in a SwiftUI-like syntax.
///
/// ```swift
/// DioramaView(region: region) {
///     DioramaMarker("A", coordinate: coord1)
///     DioramaPolyline(coordinates: [coord1, coord2])
/// }
/// ```
@resultBuilder
public struct DioramaContentBuilder {
    /// Admits any content value as an expression, which is what lets a `for` loop's body or a
    /// bare statement produce content without wrapping.
    public static func buildExpression(_ content: some DioramaContent) -> DioramaContentGroup {
        DioramaContentGroup(items: content.items)
    }

    /// A bare ``Feature`` is content on its own, drawn with the default style.
    public static func buildExpression(_ feature: Feature) -> DioramaContentGroup {
        DioramaContentGroup(items: [.annotation(DioramaFeature(feature))])
    }

    public static func buildBlock(_ components: DioramaContentGroup...) -> DioramaContentGroup {
        DioramaContentGroup(items: components.enumerated().flatMap { index, component in
            component.items.map { $0.scoped(to: .statement(index)) }
        })
    }

    public static func buildOptional(_ component: DioramaContentGroup?) -> DioramaContentGroup {
        component ?? .empty
    }

    public static func buildEither(first component: DioramaContentGroup) -> DioramaContentGroup {
        DioramaContentGroup(items: component.items.map { $0.scoped(to: .branch(true)) })
    }

    public static func buildEither(second component: DioramaContentGroup) -> DioramaContentGroup {
        DioramaContentGroup(items: component.items.map { $0.scoped(to: .branch(false)) })
    }

    public static func buildArray(_ components: [DioramaContentGroup]) -> DioramaContentGroup {
        DioramaContentGroup(items: components.enumerated().flatMap { index, component in
            component.items.map { $0.scoped(to: .iteration(index)) }
        })
    }

    public static func buildLimitedAvailability(_ component: DioramaContentGroup) -> DioramaContentGroup {
        component
    }
}

// MARK: - Proxy

/// Places geographic coordinates on the diorama for the content that annotates it.
///
/// A thin façade over a ``DioramaProjection``: the projection answers where a coordinate is, and
/// this decides whether that place is on the model. Keeping the two apart matters because a line
/// crossing the outline needs positions for the vertices that fall outside it, while a pin that
/// lands outside is simply not drawn.
struct DioramaProxy: Sendable {
    let configuration: DioramaConfiguration
    let physicalSize: Float

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
        self.physicalSize = configuration.physicalSize
        self.projection = projection ?? EllipsoidProjection(
            center: configuration.center,
            radiusMeters: configuration.radiusMeters,
            physicalSize: configuration.physicalSize
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
