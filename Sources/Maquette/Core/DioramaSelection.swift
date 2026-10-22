import RealityKit
import SwiftUI

/// Immutable type erasure for a sendable selection value.
///
/// `AnyHashable` does not declare Sendable. The only values admitted here are Hashable & Sendable,
/// and the box never exposes mutable storage. Keep the concrete type in equality as well: an Int
/// tag must not accidentally match a numerically equal tag of another type.
struct DioramaSelectionTag: @unchecked Sendable, Equatable {
    private let type: ObjectIdentifier
    private let value: AnyHashable

    init<Value: Hashable & Sendable>(_ value: Value) {
        self.type = ObjectIdentifier(Value.self)
        self.value = AnyHashable(value)
    }

    func value<Value>(as type: Value.Type) -> Value? {
        guard self.type == ObjectIdentifier(type) else { return nil }
        return value.base as? Value
    }
}

/// A binding erased at the view boundary; platform models never need to know its concrete type.
@MainActor
struct DioramaSelection {
    private let read: () -> DioramaSelectionTag?
    private let write: (DioramaSelectionTag?) -> Void
    private let accepts: (DioramaSelectionTag) -> Bool
    let usesAnnotationIDs: Bool

    init<Value: Hashable & Sendable>(_ binding: Binding<Value?>) {
        read = { binding.wrappedValue.map(DioramaSelectionTag.init) }
        write = { tag in binding.wrappedValue = tag?.value(as: Value.self) }
        accepts = { $0.value(as: Value.self) != nil }
        usesAnnotationIDs = Value.self == String.self
    }

    var wrappedValue: DioramaSelectionTag? { read() }

    func tag(for identity: DioramaMarkerIdentity) -> DioramaSelectionTag? {
        if let tag = identity.tag { return accepts(tag) ? tag : nil }
        return usesAnnotationIDs && identity.allowsLegacyID ? DioramaSelectionTag(identity.annotationID) : nil
    }

    /// Untagged or differently typed content does not clear another item's selection.
    func toggle(_ identity: DioramaMarkerIdentity) {
        guard let tag = tag(for: identity) else { return }
        write(wrappedValue == tag ? nil : tag)
    }

    func isSelected(_ identity: DioramaMarkerIdentity) -> Bool {
        guard let selected = wrappedValue else { return false }
        return tag(for: identity) == selected
    }
}

/// Selection identity survives multipart expansion without parsing entity names.
struct DioramaMarkerIdentity: Component, Equatable {
    let annotationID: String
    let tag: DioramaSelectionTag?
    var allowsLegacyID = true
}

extension DioramaContent {
    /// Associates content with a value in the diorama's selection binding.
    ///
    /// The value's type must match the binding's type. Tags are independent of rendering identity;
    /// use collection IDs or explicit annotation IDs to preserve identity when geometry changes.
    /// Multiple features can share a tag and are then selected together. Geographic shapes require a tag.
    /// - Complexity: O(*n*), where *n* is the number of content items.
    public func tag<Value: Hashable & Sendable>(_ value: Value) -> DioramaStyledContent<Self> {
        DioramaStyledContent(content: self, selectionTag: DioramaSelectionTag(value))
    }
}
