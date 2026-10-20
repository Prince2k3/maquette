import CoreGraphics
import Foundation
import SwiftUI

/// Width is measured on the physical chunk or on the geographic ground, never in screen pixels.
public struct DioramaStrokeStyle: Sendable, Equatable {
    /// The shape of an open stroke endpoint.
    public enum Cap: Sendable { case butt, round, square }
    /// How consecutive segments meet.
    public enum Join: Sendable { case miter, round, bevel }
    /// Full stroke width in explicit physical or geographic meters.
    public var width: DioramaLineWidth
    /// Endpoint treatment; closed outlines have no end caps.
    public var lineCap: Cap
    /// Treatment at each change of direction.
    public var lineJoin: Join
    /// Maximum miter length as a multiple of half the width, before beveling.
    public var miterLimit: Double
    /// Dash lengths and phase use the width's unit system. An odd pattern repeats twice.
    public var dash: [Double]
    /// Distance into the repeating dash pattern at the source path origin.
    public var dashPhase: Double
    /// Creates a stroke style. Dash entries must be finite and positive; miter limit is at least one.
    public init(width: DioramaLineWidth = .physicalMeters(0.003), lineCap: Cap = .butt,
                lineJoin: Join = .miter, miterLimit: Double = 10, dash: [Double] = [], dashPhase: Double = 0) {
        self.width = width; self.lineCap = lineCap; self.lineJoin = lineJoin
        self.miterLimit = miterLimit; self.dash = dash; self.dashPhase = dashPhase
    }
}

/// A polygon with an exterior and optional holes, rendered through the same path as GeoJSON.
public struct DioramaPolygon: DioramaContent, Sendable, Equatable {
    /// The feature and style represented by this primitive.
    public var annotation: DioramaFeature
    /// Creates an area from an exterior ring and optional holes.
    public init(_ polygon: Polygon, id: String? = nil) {
        annotation = DioramaFeature(Feature(geometry: .polygon(polygon)), id: id)
    }
    /// Creates a multipart area whose parts share selection identity.
    public init(_ polygons: MultiPolygon, id: String? = nil) {
        annotation = DioramaFeature(Feature(geometry: .multiPolygon(polygons)), id: id)
    }
    /// The renderer content produced by this primitive.
    public var items: [DioramaContentItem] { annotation.items }
}

/// A geographic circle. Identity uses center/radius, independently of rendered subdivision.
public struct DioramaCircle: DioramaContent, Sendable, Equatable {
    /// The feature and style represented by this primitive.
    public var annotation: DioramaFeature
    /// Creates a circle with a geographic radius in meters.
    public init(center: Coordinate, radius: Double, id: String? = nil) {
        annotation = DioramaFeature(Feature.point(center, properties: ["maquette-circle-radius": .number(radius)]), id: id)
        annotation.overlay = .circle(center, radius)
    }
    /// The renderer content produced by this primitive.
    public var items: [DioramaContentItem] { annotation.items }
}

/// Immutable decoded image pixels. Increment revision whenever pixels change under the same ID.
///
/// CGImage is retained immutably; the unchecked Sendable conformance exposes no mutable pixel storage.
public struct DioramaImageResource: @unchecked Sendable, Equatable {
    /// Stable identity of the image source.
    public let id: String
    /// Pixel revision used to invalidate the cached texture.
    public let revision: String
    /// Credit displayed alongside the terrain provider attribution.
    public let attribution: String?
    let image: CGImage
    /// Retains immutable decoded pixels; change the revision whenever those pixels change.
    public init(id: String, revision: String, image: CGImage, attribution: String? = nil) {
        self.id = id; self.revision = revision; self.image = image; self.attribution = attribution
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.revision == rhs.revision && lhs.attribution == rhs.attribution
    }
    struct Key: Hashable { let id: String; let revision: String }
    var key: Key { .init(id: id, revision: revision) }
}

/// A north-up geographic image rectangle; opacity does not replace satellite imagery or its credit.
public struct DioramaImageOverlay: DioramaContent, Sendable, Equatable {
    /// The feature and style represented by this primitive.
    public var annotation: DioramaFeature
    /// Places an image north-up over geographic bounds, preserving UVs through clipping.
    public init(image: DioramaImageResource, bounds: GeographicBounds, id: String? = nil) {
        let polygon = Polygon([.init(latitude: bounds.north, longitude: bounds.west),
                               .init(latitude: bounds.north, longitude: bounds.east),
                               .init(latitude: bounds.south, longitude: bounds.east),
                               .init(latitude: bounds.south, longitude: bounds.west)])
        annotation = DioramaFeature(Feature(geometry: .polygon(polygon), properties: ["maquette-image": .string(image.id)]), id: id)
        annotation.overlay = .image(image, bounds)
    }
    /// The renderer content produced by this primitive.
    public var items: [DioramaContentItem] { annotation.items }
}

enum DioramaOverlayPayload: Sendable, Equatable {
    case circle(Coordinate, Double)
    case image(DioramaImageResource, GeographicBounds)
}

/// Geographic content that supports an explicit stroke.
public protocol DioramaStrokableContent: DioramaContent {}
/// Geographic area content with independent fill and stroke styles.
public protocol DioramaFillableContent: DioramaStrokableContent {}
extension DioramaPolyline: DioramaStrokableContent {}
extension DioramaFeature: DioramaFillableContent {}
extension DioramaPolygon: DioramaFillableContent {}
extension DioramaCircle: DioramaFillableContent {}
extension DioramaStyledContent: DioramaStrokableContent where Content: DioramaStrokableContent {}
extension DioramaStyledContent: DioramaFillableContent where Content: DioramaFillableContent {}

extension DioramaStrokableContent {
    /// Applies a stroke with an explicit width.
    public func stroke(_ color: Color, width: DioramaLineWidth) -> DioramaStyledContent<Self> {
        stroke(color, style: .init(width: width))
    }
    /// Applies color, width, caps, joins, and dash settings independently of the fill.
    public func stroke(_ color: Color, style: DioramaStrokeStyle) -> DioramaStyledContent<Self> {
        DioramaStyledContent(content: self, tint: color, stroke: color, strokeStyle: style)
    }
}
extension DioramaFillableContent {
    /// Applies an area fill without changing the stroke.
    public func fill(_ color: Color) -> DioramaStyledContent<Self> { DioramaStyledContent(content: self, fill: color) }
}
extension DioramaStyledContent where Content: DioramaStrokableContent {
    /// Applies a stroke with an explicit width.
    public func stroke(_ color: Color, width: DioramaLineWidth) -> Self { stroke(color, style: .init(width: width)) }
    /// Applies color, width, caps, joins, and dash settings independently of the fill.
    public func stroke(_ color: Color, style: DioramaStrokeStyle) -> Self {
        var copy = self; copy.tintValue = color; copy.strokeValue = color; copy.strokeStyleValue = style; return copy
    }
}
extension DioramaStyledContent where Content: DioramaFillableContent {
    /// Applies an area fill without changing the stroke.
    public func fill(_ color: Color) -> Self { var copy = self; copy.fillValue = color; return copy }
}
