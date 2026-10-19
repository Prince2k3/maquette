import Foundation
import os

/// Maps typed collection identity onto the renderer's string keys, scoped to one store.
/// Only current content is retained, so visiting new collections does not grow a global registry.
struct DioramaContentIdentityResolver {
    private static let logger = Logger(maquette: "DioramaContentIdentityResolver")
    private(set) var identifiers: [DioramaContentIdentity: String] = [:]
    private(set) var duplicateIdentifiers: Set<String> = []

    mutating func resolve(_ content: DioramaContentGroup) -> DioramaContentGroup {
        var next: [DioramaContentIdentity: String] = [:]
        let reserved = Set(content.items.compactMap { item -> String? in
            guard case .annotation(let annotation) = item else { return nil }
            return annotation.id
        })
        let items = content.items.map { item -> DioramaContentItem in
            guard case .annotation(var annotation) = item,
                  let identity = annotation.contentIdentity,
                  identity.scopes.contains(where: {
                      if case .element = $0 { return true }
                      return false
                  })
            else { return item }

            var identifier = next[identity] ?? identifiers[identity] ?? "collection-\(UUID().uuidString)"
            // Explicit application IDs may use any spelling, including our generated prefix.
            while reserved.contains(identifier) {
                identifier = "collection-\(UUID().uuidString)"
            }
            next[identity] = identifier
            annotation.selectionAnnotationID = annotation.selectionAnnotationID ?? annotation.id
            annotation.id = identifier
            return .annotation(annotation)
        }
        identifiers = next
        var seen: Set<String> = []
        var duplicates: Set<String> = []
        for item in items {
            guard case .annotation(let annotation) = item else { continue }
            if !seen.insert(annotation.id).inserted { duplicates.insert(annotation.id) }
        }
        let newlyDuplicated = duplicates.subtracting(duplicateIdentifiers)
        if !newlyDuplicated.isEmpty {
            Self.logger.warning(
                "Found \(newlyDuplicated.count) duplicate annotation identities. Give collection elements and annotations unique IDs; duplicates share one rendered item."
            )
        }
        duplicateIdentifiers = duplicates
        return DioramaContentGroup(items: items)
    }
}
