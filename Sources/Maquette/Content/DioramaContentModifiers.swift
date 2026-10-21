import SwiftUI

extension DioramaContent {
    /// Flattens a reusable body's content into renderer items.
    public var items: [DioramaContentItem] { body.items }

    /// Supplies a tint to annotations that have no more local tint modifier.
    public func tint(_ color: Color) -> DioramaStyledContent<Self> {
        DioramaStyledContent(content: self, tint: color)
    }

    /// Applies overall content opacity, clamped to zero through one.
    public func opacity(_ value: Double) -> DioramaStyledContent<Self> {
        DioramaStyledContent(content: self, opacity: value)
    }

    /// Supplies an altitude interpretation to annotations without a more local modifier.
    public func altitudeReference(_ reference: AltitudeReference) -> DioramaStyledContent<Self> {
        DioramaStyledContent(content: self, altitude: reference)
    }
}

extension DioramaContent where Body == Never {
    /// Primitive content is flattened through `items`; its body is never evaluated.
    public var body: Never { fatalError("Primitive diorama content has no body") }
}

extension Never: DioramaContent {
    /// An uninhabited content value cannot produce renderer items.
    public var items: [DioramaContentItem] { switch self {} }
}

/// A ribbon width with explicit physical units in the diorama's coordinate space.
public enum DioramaLineWidth: Sendable, Equatable {
    /// Width in physical metres of the rendered diorama, independent of geographic scale.
    case physicalMeters(Float)
    /// Width in geographic meters; converted locally through the active projection.
    case geographicMeters(Double)
}

/// Content with inherited annotation styling. Local child modifiers take precedence.
///
/// Chaining the same modifier on this value replaces its earlier value. Styling a group
/// supplies defaults while preserving modifiers already applied inside the group.
public struct DioramaStyledContent<Content: DioramaContent>: DioramaContent {
    let content: Content
    var tintValue: Color?
    var altitudeValue: AltitudeReference?
    var strokeStyleValue: DioramaStrokeStyle?
    var fillValue: Color?
    var strokeValue: Color?
    var opacityValue: Double?
    var selectionTagValue: DioramaSelectionTag?

    init(
        content: Content, tint: Color? = nil, altitude: AltitudeReference? = nil,
        stroke: Color? = nil, strokeStyle: DioramaStrokeStyle? = nil, fill: Color? = nil,
        opacity: Double? = nil, selectionTag: DioramaSelectionTag? = nil
    ) {
        self.content = content
        tintValue = tint
        altitudeValue = altitude
        strokeStyleValue = strokeStyle
        fillValue = fill
        strokeValue = stroke
        opacityValue = opacity
        selectionTagValue = selectionTag
    }

    /// The styled renderer items, retaining annotation identities and route previews.
    public var items: [DioramaContentItem] {
        content.items.map { item in
            guard case .annotation(var annotation) = item else { return item }
            if let tintValue, annotation.contentStyleOverrides & 1 == 0 {
                annotation.style.tint = tintValue
                annotation.contentStyleOverrides |= 1
            }
            if let altitudeValue, annotation.contentStyleOverrides & 2 == 0 {
                annotation.style.altitude = altitudeValue
                annotation.contentStyleOverrides |= 2
            }
            if let strokeStyleValue, annotation.contentStyleOverrides & 4 == 0 {
                annotation.style.strokeStyle = strokeStyleValue
                annotation.contentStyleOverrides |= 4
            }
            if let fillValue, annotation.contentStyleOverrides & 8 == 0 {
                annotation.style.fill = fillValue
                annotation.contentStyleOverrides |= 8
            }
            if let strokeValue, annotation.contentStyleOverrides & 16 == 0 {
                annotation.style.stroke = strokeValue
                annotation.contentStyleOverrides |= 16
            }
            if let opacityValue, annotation.contentStyleOverrides & 32 == 0 {
                annotation.style.opacity = opacityValue
                annotation.contentStyleOverrides |= 32
            }
            if let selectionTagValue, annotation.selectionTag == nil {
                annotation.selectionTag = selectionTagValue
            }
            return .annotation(annotation)
        }
    }

    /// Associates this modifier layer with a typed selection value without changing its styling.
    public func tag<Value: Hashable & Sendable>(_ value: Value) -> Self {
        var copy = self
        copy.selectionTagValue = DioramaSelectionTag(value)
        return copy
    }

    /// Applies overall content opacity, clamped to zero through one.
    public func opacity(_ value: Double) -> Self { var copy = self; copy.opacityValue = value; return copy }

    /// Replaces the tint on this modifier layer.
    public func tint(_ color: Color) -> Self {
        var copy = self
        copy.tintValue = color
        return copy
    }

    /// Replaces the altitude interpretation on this modifier layer.
    public func altitudeReference(_ reference: AltitudeReference) -> Self {
        var copy = self
        copy.altitudeValue = reference
        return copy
    }
}

// AnyHashable is safe here because its only entry point requires a Sendable value.
struct DioramaContentID: Hashable, @unchecked Sendable {
    let value: AnyHashable
    init<ID: Hashable & Sendable>(_ value: ID) {
        self.value = AnyHashable(TypedID(value: value))
    }
    private struct TypedID<ID: Hashable & Sendable>: Hashable, Sendable {
        let value: ID
    }
}

enum ContentScope: Hashable, Sendable {
    case statement(Int)
    case branch(Bool)
    case iteration(Int)
    case element(DioramaContentID)
}

/// Structural identity used by the store to assign collision-free renderer names.
struct DioramaContentIdentity: Hashable, Sendable {
    var scopes: [ContentScope]
    var annotationID: String
}

extension DioramaContentItem {
    func scoped(to scope: ContentScope) -> Self {
        guard case .annotation(var annotation) = self else { return self }
        if case .branch = scope, annotation.viewAnnotation == nil { return self }
        var identity = annotation.contentIdentity ?? DioramaContentIdentity(
            scopes: [], annotationID: annotation.id
        )
        if case .element = scope, annotation.viewAnnotation?.hasExplicitID != true {
            identity.annotationID = ""
        }
        identity.scopes.insert(scope, at: 0)
        annotation.contentIdentity = identity
        return .annotation(annotation)
    }
}

// Calling SwiftUI's unconstrained initializer here keeps the specialized content-builder
// overloads below from recursively selecting themselves.
private func makeForEach<Data: RandomAccessCollection, ID: Hashable, Content>(
    _ data: Data, id: KeyPath<Data.Element, ID>, content: @escaping (Data.Element) -> Content
) -> ForEach<Data, ID, Content> {
    ForEach(data, id: id, content: content)
}

/// The identity-bearing element produced by a diorama `ForEach` initializer.
///
/// Declare `ForEach` inside a diorama builder, or pass an element closure annotated with
/// `@DioramaContentBuilder`. A `ForEach` explicitly specialized to another content type,
/// such as `DioramaMarker`, is not diorama content because SwiftUI does not expose its ID key path.
public struct DioramaForEachContent: DioramaContent, Sendable {
    let group: DioramaContentGroup

    init(group: DioramaContentGroup) { self.group = group }

    /// The flattened items carrying their typed collection identity.
    public var items: [DioramaContentItem] { group.items }
}

extension ForEach: DioramaContent where Content == DioramaForEachContent {
    /// Flattens every element's diorama content in collection order.
    public var items: [DioramaContentItem] { data.flatMap { content($0).items } }
}

extension ForEach where Content == DioramaForEachContent, ID: Sendable {
    /// Repeats diorama content with stable, typed identity from a key path.
    ///
    /// Child annotations retain their identity across changes to their data and collection
    /// order. Sibling collection declarations receive separate structural namespaces.
    public init(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        @DioramaContentBuilder content: @escaping (Data.Element) -> DioramaContentGroup
    ) {
        self = makeForEach(data, id: id) { element in
            var occurrences: [[ContentScope]: Int] = [:]
            let items = content(element).items.map { item in
                // A conditional sibling may disappear. Its absence must not renumber another
                // child's structural path. Occurrence disambiguates legacy multi-item values
                // whose individual children have no builder path of their own.
                let path: [ContentScope]
                if case .annotation(let annotation) = item {
                    path = annotation.contentIdentity?.scopes ?? []
                } else {
                    return item
                }
                let occurrence = occurrences[path, default: 0]
                occurrences[path] = occurrence + 1
                return item.scoped(to: .iteration(occurrence))
                    .scoped(to: .element(DioramaContentID(element[keyPath: id])))
            }
            return DioramaForEachContent(group: DioramaContentGroup(items: items))
        }
    }
}

extension ForEach where Content == DioramaForEachContent, Data.Element: Identifiable,
                        ID == Data.Element.ID, ID: Sendable {
    /// Repeats diorama content using each identifiable element's stable identity.
    public init(
        _ data: Data,
        @DioramaContentBuilder content: @escaping (Data.Element) -> DioramaContentGroup
    ) {
        self.init(data, id: \.id, content: content)
    }
}


/// Content with an explicit feature identity, independent of its selection tag.
public struct DioramaIdentifiedContent<Content: DioramaContent>: DioramaContent {
    let content: Content
    let identifier: String
    /// Renderer items retaining the explicit public identity for camera fitting.
    public var items: [DioramaContentItem] {
        content.items.map { item in
            guard case .annotation(var feature) = item else { return item }
            feature.viewAnnotation?.hasExplicitID = true
            feature.id = identifier
            feature.selectionAnnotationID = nil
            feature.contentIdentity?.annotationID = identifier
            return .annotation(feature)
        }
    }
}

extension DioramaContent {
    /// Sets the feature ID used for stable rendering and camera content-ID fits.
    /// Apply this to one primitive; collection elements should retain their own unique IDs.
    public func id(_ identifier: String) -> DioramaIdentifiedContent<Self> {
        DioramaIdentifiedContent(content: self, identifier: identifier)
    }
}
extension DioramaIdentifiedContent: DioramaStrokableContent where Content: DioramaStrokableContent {}
extension DioramaIdentifiedContent: DioramaFillableContent where Content: DioramaFillableContent {}
