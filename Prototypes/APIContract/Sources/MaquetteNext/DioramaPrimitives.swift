import CoreGraphics
import Maquette
import SwiftUI

public enum DioramaLineWidth: Sendable, Equatable {
    case physicalMeters(Float)
    case geographicMeters(Double)
}

public struct DioramaStrokeStyle: Sendable, Equatable {
    public enum Cap: Sendable { case butt, round, square }
    public enum Join: Sendable { case miter, round, bevel }
    public var width: DioramaLineWidth
    public var lineCap: Cap
    public var lineJoin: Join
    public var miterLimit: Double
    public var dash: [Double]
    public var dashPhase: Double
    public init(width: DioramaLineWidth, lineCap: Cap = .butt, lineJoin: Join = .miter,
                miterLimit: Double = 10, dash: [Double] = [], dashPhase: Double = 0) {
        self.width = width; self.lineCap = lineCap; self.lineJoin = lineJoin
        self.miterLimit = miterLimit; self.dash = dash; self.dashPhase = dashPhase
    }
}

struct ResolvedStyle: Sendable, Equatable {
    var tint: Color?
    var fill: Color?
    var stroke: Color?
    var strokeStyle: DioramaStrokeStyle?
    var opacity: Double?
    var altitude: AltitudeReference?
    mutating func inherit(_ other: Self) {
        tint = tint ?? other.tint; fill = fill ?? other.fill
        stroke = stroke ?? other.stroke; strokeStyle = strokeStyle ?? other.strokeStyle
        opacity = opacity ?? other.opacity; altitude = altitude ?? other.altitude
    }
}

public struct DioramaFeatureStyle: Sendable, Equatable {
    public var pointTint: Color
    public var stroke: Color
    public var fill: Color
    public var strokeStyle: DioramaStrokeStyle
    public init(pointTint: Color = .red, stroke: Color = .blue, fill: Color = .blue.opacity(0.2),
                strokeStyle: DioramaStrokeStyle = .init(width: .physicalMeters(0.003))) {
        self.pointTint = pointTint; self.stroke = stroke; self.fill = fill; self.strokeStyle = strokeStyle
    }
}

public struct DioramaFeature: DioramaContent, PrimitiveContent {
    let feature: Feature
    let style: DioramaFeatureStyle?
    public init(_ feature: Feature, style: DioramaFeatureStyle? = nil) { self.feature = feature; self.style = style }
    func resolve() -> ResolvedContent {
        var descriptor = ContentDescriptor(geometry: .feature(feature))
        if let style {
            descriptor.style.tint = style.pointTint; descriptor.style.fill = style.fill
            descriptor.style.stroke = style.stroke; descriptor.style.strokeStyle = style.strokeStyle
        }
        return ResolvedContent(entries: [.init(descriptor: descriptor)])
    }
}

public struct DioramaMarker: DioramaContent, PrimitiveContent {
    let feature: Feature
    public init(_ title: String = "", coordinate: Coordinate) {
        feature = Feature.point(coordinate, properties: ["title": .string(title)])
    }
    func resolve() -> ResolvedContent { MaquetteNext.resolve(DioramaFeature(feature)) }
}

public struct DioramaPolyline: DioramaStrokableContent, PrimitiveContent {
    let feature: Feature
    public init(coordinates: [Coordinate]) { feature = Feature.line(coordinates) }
    public init(_ line: LineString) { feature = Feature(geometry: .lineString(line)) }
    public init(_ lines: MultiLineString) { feature = Feature(geometry: .multiLineString(lines)) }
    func resolve() -> ResolvedContent { MaquetteNext.resolve(DioramaFeature(feature)) }
}

public struct DioramaPolygon: DioramaFillableContent, PrimitiveContent {
    let feature: Feature
    public init(_ polygon: Polygon) { feature = Feature(geometry: .polygon(polygon)) }
    public init(_ polygons: MultiPolygon) { feature = Feature(geometry: .multiPolygon(polygons)) }
    func resolve() -> ResolvedContent { MaquetteNext.resolve(DioramaFeature(feature)) }
}

public struct DioramaCircle: DioramaFillableContent, PrimitiveContent {
    let center: Coordinate
    let radius: Double
    public init(center: Coordinate, radius: Double) { self.center = center; self.radius = radius }
    func resolve() -> ResolvedContent {
        ResolvedContent(entries: [.init(descriptor: .init(geometry: .circle(center: center, radius: radius)))])
    }
}

public struct DioramaAnnotation<Label: View>: DioramaContent, PrimitiveContent {
    let title: String
    let coordinate: Coordinate
    let anchor: UnitPoint
    let label: () -> Label
    public init(_ title: String, coordinate: Coordinate, anchor: UnitPoint = .center,
                @ViewBuilder content: @escaping @MainActor () -> Label) {
        self.title = title; self.coordinate = coordinate; self.anchor = anchor; label = content
    }
    func resolve() -> ResolvedContent {
        ResolvedContent(entries: [.init(
            descriptor: .init(geometry: .annotation(title: title, coordinate: coordinate, anchor: anchor)),
            view: { AnyView(label()) }
        )])
    }
}

struct ImageKey: Sendable, Equatable { let id: String; let revision: String }

/// Prototype resource owned by the caller; view/image storage remains main-actor isolated.
@MainActor
public struct DioramaImageResource {
    let key: ImageKey
    let image: CGImage
    public init(id: String, revision: String, image: CGImage) {
        key = ImageKey(id: id, revision: revision); self.image = image
    }
}

public struct DioramaImageOverlay: DioramaContent, PrimitiveContent {
    let image: DioramaImageResource
    let bounds: GeographicBounds
    public init(image: DioramaImageResource, bounds: GeographicBounds) { self.image = image; self.bounds = bounds }
    func resolve() -> ResolvedContent {
        ResolvedContent(entries: [.init(
            descriptor: .init(geometry: .image(bounds: bounds, resource: image.key)), image: image.image
        )])
    }
}
