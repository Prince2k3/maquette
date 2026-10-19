import SwiftUI

extension DioramaContent {
    /// Flattens a reusable body's content into renderer items.
    public var items: [DioramaContentItem] { body.items }

    /// Supplies a tint to annotations that have no more local tint modifier.
    public func tint(_ color: Color) -> DioramaStyledContent<Self> {
        DioramaStyledContent(content: self, tint: color)
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

    var meters: Float {
        switch self { case .physicalMeters(let value): value }
    }
}

/// Content with inherited annotation styling. Local child modifiers take precedence.
///
/// Chaining the same modifier on this value replaces its earlier value. Styling a group
/// supplies defaults while preserving modifiers already applied inside the group.
public struct DioramaStyledContent<Content: DioramaContent>: DioramaContent {
    let content: Content
    var tintValue: Color?
    var altitudeValue: AltitudeReference?
    var widthValue: Float?
    var selectionTagValue: DioramaSelectionTag?

    init(
        content: Content, tint: Color? = nil, altitude: AltitudeReference? = nil,
        width: Float? = nil, selectionTag: DioramaSelectionTag? = nil
    ) {
        self.content = content
        tintValue = tint
        altitudeValue = altitude
        widthValue = width
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
            if let widthValue, annotation.contentStyleOverrides & 4 == 0 {
                annotation.style.lineWidth = widthValue
                annotation.contentStyleOverrides |= 4
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

extension DioramaPolyline {
    /// Colors the ribbon and sets its width in explicit diorama units.
    public func stroke(_ color: Color, width: DioramaLineWidth) -> DioramaStyledContent<Self> {
        DioramaStyledContent(content: self, tint: color, width: width.meters)
    }
}

extension DioramaStyledContent where Content == DioramaPolyline {
    /// Replaces the ribbon's color and width on this modifier layer.
    public func stroke(_ color: Color, width: DioramaLineWidth) -> Self {
        var copy = self
        copy.tintValue = color
        copy.widthValue = width.meters
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
        var identity = annotation.contentIdentity ?? DioramaContentIdentity(
            scopes: [], annotationID: annotation.id
        )
        if case .element = scope { identity.annotationID = "" }
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
