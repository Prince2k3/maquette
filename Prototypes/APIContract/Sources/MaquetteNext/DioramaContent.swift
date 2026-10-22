import CoreGraphics
import Maquette
import SwiftUI

public typealias Coordinate = Maquette.Coordinate
public typealias Feature = Maquette.Feature
public typealias FeatureCollection = Maquette.FeatureCollection
public typealias Polygon = Maquette.Polygon
public typealias MultiPolygon = Maquette.MultiPolygon
public typealias LinearRing = Maquette.LinearRing
public typealias LineString = Maquette.LineString
public typealias MultiLineString = Maquette.MultiLineString
public typealias GeographicBounds = Maquette.GeographicBounds
public typealias DioramaRegion = Maquette.DioramaRegion
public typealias DioramaGroundPosition = Maquette.DioramaGroundPosition
public typealias AltitudeReference = Maquette.AltitudeReference

/// Contract prototype: reusable declarations expose a body, never renderer storage.
@MainActor
public protocol DioramaContent {
    associatedtype Body: DioramaContent = Never
    @DioramaContentBuilder var body: Body { get }
}

extension Never: DioramaContent {
    public var body: Never { return fatalError("Never has no content") }
}

extension DioramaContent where Body == Never {
    public var body: Never { fatalError("Primitive content is resolved internally") }
}

@MainActor
protocol PrimitiveContent {
    func resolve() -> ResolvedContent
}

@MainActor
func resolve<C: DioramaContent>(_ content: C) -> ResolvedContent {
    if let primitive = content as? any PrimitiveContent { return primitive.resolve() }
    precondition(C.Body.self != Never.self, "Custom content must provide a body")
    return resolve(content.body)
}

/// Typed IDs do not equate an Int tag with a numerically equal Double tag.
struct TypedValue: Hashable, @unchecked Sendable {
    let value: AnyHashable
    let type: ObjectIdentifier
    init<T: Hashable & Sendable>(_ value: T) {
        self.value = AnyHashable(value)
        type = ObjectIdentifier(T.self)
    }
}

enum IdentityScope: Hashable, Sendable {
    case statement(Int), iteration(Int), branch(Bool), element(TypedValue), explicit(TypedValue)
}

struct ContentKey: Hashable, Sendable { var path: [IdentityScope] = [] }

enum GeometryDescriptor: Sendable, Equatable {
    case feature(Feature)
    case circle(center: Coordinate, radius: Double)
    case image(bounds: GeographicBounds, resource: ImageKey)
    case annotation(title: String, coordinate: Coordinate, anchor: UnitPoint)
}

struct ContentDescriptor: Sendable, Equatable {
    var key = ContentKey()
    var geometry: GeometryDescriptor
    var style = ResolvedStyle()
    var tag: TypedValue?
}

@MainActor
struct ResolvedContent {
    struct Entry {
        var descriptor: ContentDescriptor
        // Never crosses isolation with the sendable descriptor.
        var view: (() -> AnyView)?
        var image: CGImage?
    }
    var entries: [Entry] = []

    func scoped(_ scope: IdentityScope) -> Self {
        var copy = self
        for index in copy.entries.indices { copy.entries[index].descriptor.key.path.insert(scope, at: 0) }
        return copy
    }
}

/// A builder result; its storage is intentionally internal.
public struct DioramaContentGroup: DioramaContent, PrimitiveContent {
    let content: ResolvedContent
    public init(@DioramaContentBuilder content: () -> DioramaContentGroup) { self = content() }
    init(_ content: ResolvedContent = .init()) { self.content = content }
    func resolve() -> ResolvedContent { content }
}

@resultBuilder @MainActor
public enum DioramaContentBuilder {
    public static func buildExpression(_ content: some DioramaContent) -> DioramaContentGroup {
        DioramaContentGroup(resolve(content))
    }
    public static func buildExpression(_ feature: Feature) -> DioramaContentGroup {
        buildExpression(DioramaFeature(feature))
    }
    public static func buildExpression(_ collection: FeatureCollection) -> DioramaContentGroup {
        buildArray(collection.features.map { buildExpression($0) })
    }
    public static func buildBlock(_ groups: DioramaContentGroup...) -> DioramaContentGroup {
        DioramaContentGroup(ResolvedContent(entries: groups.enumerated().flatMap {
            $0.element.content.scoped(.statement($0.offset)).entries
        }))
    }
    public static func buildOptional(_ group: DioramaContentGroup?) -> DioramaContentGroup { group ?? .init() }
    public static func buildEither(first: DioramaContentGroup) -> DioramaContentGroup {
        DioramaContentGroup(first.content.scoped(.branch(true)))
    }
    public static func buildEither(second: DioramaContentGroup) -> DioramaContentGroup {
        DioramaContentGroup(second.content.scoped(.branch(false)))
    }
    public static func buildArray(_ groups: [DioramaContentGroup]) -> DioramaContentGroup {
        DioramaContentGroup(ResolvedContent(entries: groups.enumerated().flatMap {
            $0.element.content.scoped(.iteration($0.offset)).entries
        }))
    }
    public static func buildLimitedAvailability(_ group: DioramaContentGroup) -> DioramaContentGroup { group }
}

/// Styling is resolved locally before inherited defaults are supplied.
public struct DioramaModifiedContent<Content: DioramaContent>: DioramaContent, PrimitiveContent {
    let content: Content
    var overrides = ResolvedStyle()
    var explicitID: TypedValue?
    var tagValue: TypedValue?
    func resolve() -> ResolvedContent {
        var result = MaquetteNext.resolve(content)
        for index in result.entries.indices {
            result.entries[index].descriptor.style.inherit(overrides)
            if result.entries[index].descriptor.tag == nil { result.entries[index].descriptor.tag = tagValue }
        }
        if let explicitID { result = result.scoped(.explicit(explicitID)) }
        return result
    }
    public func tint(_ color: Color) -> Self { var copy = self; copy.overrides.tint = color; return copy }
    public func opacity(_ value: Double) -> Self { var copy = self; copy.overrides.opacity = value; return copy }
    public func altitudeReference(_ value: AltitudeReference) -> Self { var copy = self; copy.overrides.altitude = value; return copy }
    public func id<ID: Hashable & Sendable>(_ value: ID) -> Self { var copy = self; copy.explicitID = TypedValue(value); return copy }
    public func tag<Tag: Hashable & Sendable>(_ value: Tag) -> Self { var copy = self; copy.tagValue = TypedValue(value); return copy }
}

extension DioramaModifiedContent where Content: DioramaStrokableContent {
    public func stroke(_ color: Color, width: DioramaLineWidth) -> Self {
        stroke(color, style: DioramaStrokeStyle(width: width))
    }
    public func stroke(_ color: Color, style: DioramaStrokeStyle) -> Self {
        var copy = self; copy.overrides.stroke = color; copy.overrides.strokeStyle = style; return copy
    }
}
extension DioramaModifiedContent where Content: DioramaFillableContent {
    public func fill(_ color: Color) -> Self { var copy = self; copy.overrides.fill = color; return copy }
}

extension DioramaContent {
    public func tint(_ color: Color) -> DioramaModifiedContent<Self> { DioramaModifiedContent(content: self).tint(color) }
    public func opacity(_ value: Double) -> DioramaModifiedContent<Self> { DioramaModifiedContent(content: self).opacity(value) }
    public func altitudeReference(_ value: AltitudeReference) -> DioramaModifiedContent<Self> {
        DioramaModifiedContent(content: self).altitudeReference(value)
    }
    public func id<ID: Hashable & Sendable>(_ value: ID) -> DioramaModifiedContent<Self> { DioramaModifiedContent(content: self).id(value) }
    public func tag<Tag: Hashable & Sendable>(_ value: Tag) -> DioramaModifiedContent<Self> { DioramaModifiedContent(content: self).tag(value) }
}

/// Only line and area content expose stroke; only areas expose fill.
@MainActor public protocol DioramaStrokableContent: DioramaContent {}
@MainActor public protocol DioramaFillableContent: DioramaStrokableContent {}
extension DioramaStrokableContent {
    public func stroke(_ color: Color, width: DioramaLineWidth) -> DioramaModifiedContent<Self> {
        DioramaModifiedContent(content: self).stroke(color, width: width)
    }
    public func stroke(_ color: Color, style: DioramaStrokeStyle) -> DioramaModifiedContent<Self> {
        DioramaModifiedContent(content: self).stroke(color, style: style)
    }
}
extension DioramaFillableContent {
    public func fill(_ color: Color) -> DioramaModifiedContent<Self> { DioramaModifiedContent(content: self).fill(color) }
}

// Retain modifier applicability after .tag/.id/.opacity as well as after .stroke/.fill.
extension DioramaModifiedContent: DioramaStrokableContent where Content: DioramaStrokableContent {}
extension DioramaModifiedContent: DioramaFillableContent where Content: DioramaFillableContent {}

public struct DioramaForEachContent: DioramaContent, PrimitiveContent, View {
    public typealias Body = Never
    public var body: Never { return fatalError("Primitive content is resolved internally") }
    let content: ResolvedContent
    func resolve() -> ResolvedContent { content }
}

private func nativeForEach<Data: RandomAccessCollection, ID: Hashable, Content: View>(
    _ data: Data, id: KeyPath<Data.Element, ID>, content: @escaping (Data.Element) -> Content
) -> ForEach<Data, ID, Content> { ForEach(data, id: id, content: content) }

extension ForEach: DioramaContent where Content == DioramaForEachContent {
    public typealias Body = Never
}
extension ForEach: PrimitiveContent where Content == DioramaForEachContent {
    func resolve() -> ResolvedContent { ResolvedContent(entries: data.flatMap { content($0).content.entries }) }
}
extension ForEach where Content == DioramaForEachContent, ID: Sendable {
    @MainActor public init(_ data: Data, id: KeyPath<Data.Element, ID>,
                @DioramaContentBuilder content: @escaping @MainActor (Data.Element) -> DioramaContentGroup) {
        let elements = Dictionary(uniqueKeysWithValues: data.map { element in
            (element[keyPath: id], DioramaForEachContent(content:
                content(element).content.scoped(.element(TypedValue(element[keyPath: id])))))
        })
        self = nativeForEach(data, id: id) { elements[$0[keyPath: id]]! }
    }
}
extension ForEach where Content == DioramaForEachContent, Data.Element: Identifiable, ID == Data.Element.ID, ID: Sendable {
    @MainActor public init(_ data: Data, @DioramaContentBuilder content: @escaping @MainActor (Data.Element) -> DioramaContentGroup) {
        self.init(data, id: \.id, content: content)
    }
}

/// Keyed factory storage, separate from geometry descriptors and their Sendable boundary.
@MainActor
final class AnnotationRegistry {
    struct Record {
        let lifetimeID: UUID
        var descriptor: ContentDescriptor
        var makeView: () -> AnyView
    }
    private(set) var records: [ContentKey: Record] = [:]

    func reconcile(_ content: ResolvedContent) {
        var next: [ContentKey: Record] = [:]
        for entry in content.entries {
            guard let view = entry.view else { continue }
            let key = entry.descriptor.key
            precondition(next[key] == nil, "Duplicate annotation identity")
            next[key] = Record(lifetimeID: records[key]?.lifetimeID ?? UUID(), descriptor: entry.descriptor, makeView: view)
        }
        records = next
    }
}
