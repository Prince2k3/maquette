import Foundation
import Observation

/// Per-host SwiftUI label lifetimes, separate from the value snapshots supplied by builders.
@MainActor @Observable
final class DioramaAnnotationRegistry {
    @MainActor @Observable
    final class Record: Identifiable {
        let id: String
        let lifetimeID = UUID()
        var feature: DioramaFeature
        var factory: DioramaAnnotationViewFactory
        var measuredSize: CGSize = .zero
        var frame: CGRect?
        var visible = false

        var descriptor: DioramaAnnotationDescriptor? { feature.viewAnnotation }

        init(feature: DioramaFeature, factory: DioramaAnnotationViewFactory) {
            id = feature.id
            self.feature = feature
            self.factory = factory
        }
    }

    private(set) var records: [String: Record] = [:]
    private(set) var orderedRecords: [Record] = []

    /// Reconciles renderer IDs already assigned by the store's identity resolver.
    func reconcile(_ content: DioramaContentGroup) {
        var next: [String: Record] = [:]
        var ordered: [Record] = []
        for item in content.items {
            guard case .annotation(let feature) = item,
                  let descriptor = feature.viewAnnotation, descriptor.isValid,
                  feature.style.opacity.isFinite,
                  let factory = feature.viewFactory, next[feature.id] == nil else { continue }
            let record = records[feature.id] ?? Record(feature: feature, factory: factory)
            record.feature = feature
            record.factory = factory
            next[feature.id] = record
            ordered.append(record)
        }
        records = next
        orderedRecords = ordered
    }

    func updateMeasuredSize(_ size: CGSize, for id: String) {
        guard size.width.isFinite, size.height.isFinite, size.width >= 0, size.height >= 0,
              let record = records[id], record.measuredSize != size else { return }
        record.measuredSize = size
    }
}
