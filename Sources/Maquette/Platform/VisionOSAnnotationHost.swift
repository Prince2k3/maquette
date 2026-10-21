#if os(visionOS)
import RealityKit
import SwiftUI

/// Native attachments retain their SwiftUI identity while their scene entity is temporarily hidden.
/// Depth testing provides physical occlusion; volume labels do not promise screen-space overlap
/// avoidance because a volumetric window has no authoritative viewer pose.
@MainActor
final class VisionOSAnnotationHost {
    static let maximumAttachments = 256

    private struct Entry {
        let pivot: Entity
        var attachment: ViewAttachmentEntity
    }

    private var entries: [UUID: Entry] = [:]

    static func records(in registry: DioramaAnnotationRegistry) -> [DioramaAnnotationRegistry.Record] {
        Array(registry.orderedRecords.prefix(maximumAttachments))
    }

    /// Attachment taps belong to native SwiftUI controls and label selection, never marker picking.
    static func contains(_ entity: Entity) -> Bool {
        var ancestor: Entity? = entity
        while let current = ancestor {
            if current.components[DioramaAnnotationAttachmentTarget.self] != nil { return true }
            ancestor = current.parent
        }
        return false
    }

    func update(
        attachments: RealityViewAttachments,
        registry: DioramaAnnotationRegistry,
        root: Entity?,
        projection: (any DioramaProjection)?,
        configuration: DioramaConfiguration,
        visible: Bool
    ) {
        let records = Self.records(in: registry)
        let active = Set(records.map(\.lifetimeID))
        for key in Array(entries.keys) where !active.contains(key) {
            entries.removeValue(forKey: key)?.pivot.removeFromParent()
        }

        for record in records {
            // Resolve every update: RealityView may replace an attachment entity after a label
            // changes size, while the registry's lifetime and SwiftUI state remain the same.
            guard let attachment = attachments.entity(for: record.lifetimeID) else {
                entries[record.lifetimeID]?.pivot.isEnabled = false
                continue
            }
            let pivot: Entity
            if let existing = entries[record.lifetimeID] {
                pivot = existing.pivot
                if existing.attachment !== attachment {
                    existing.attachment.removeFromParent()
                    pivot.addChild(attachment)
                }
            } else {
                pivot = Entity()
                pivot.name = "MaquetteAnnotation_\(record.lifetimeID)"
                pivot.components.set(DioramaAnnotationAttachmentTarget())
                pivot.components.set(BillboardComponent())
                pivot.addChild(attachment)
            }
            // Mark the attachment itself too, so hit filtering works during a reparent.
            attachment.components.set(DioramaAnnotationAttachmentTarget())
            entries[record.lifetimeID] = Entry(pivot: pivot, attachment: attachment)
            if let root, pivot.parent !== root { root.addChild(pivot) }

            guard visible, record.feature.style.opacity > 0, let root, let projection, let descriptor = record.descriptor,
                  let point = DioramaAnnotationPlacement.position(
                    for: record.feature, projection: projection, configuration: configuration
                  ) else {
                pivot.isEnabled = false
                continue
            }

            // The attachment's native conversion from points to metres is an SDK detail. Measure
            // its intrinsic geometry and calibrate the desired physical size rather than assuming
            // one point equals a fixed number of metres. Compensate the chunk's volume-fit scale.
            let bounds = attachment.visualBounds(relativeTo: attachment)
            let pointSize = record.measuredSize
            let parentScale = root.scale(relativeTo: nil)
            let worldScale = abs(parentScale.x)
            guard pointSize.width.isFinite, pointSize.height.isFinite,
                  pointSize.width > 0, pointSize.height > 0,
                  bounds.extents.x.isFinite, bounds.extents.y.isFinite,
                  bounds.extents.x > 0, bounds.extents.y > 0,
                  worldScale.isFinite, worldScale > 0 else {
                pivot.isEnabled = false
                continue
            }
            let metresPerPoint = descriptor.metersPerPoint / worldScale
            let width = Float(pointSize.width) * metresPerPoint
            let height = Float(pointSize.height) * metresPerPoint
            let scaleX = width / bounds.extents.x
            let scaleY = height / bounds.extents.y
            guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else {
                pivot.isEnabled = false
                continue
            }
            pivot.position = point
            attachment.scale = SIMD3<Float>(scaleX, scaleY, min(scaleX, scaleY))
            // UnitPoint and offset use SwiftUI's downward-positive Y; RealityKit's Y points up.
            // A child offset leaves the geographic pivot fixed as BillboardComponent faces it
            // towards the viewer, including after the chunk itself rotates.
            let labelPosition = SIMD3<Float>(
                (0.5 - Float(descriptor.anchor.x)) * width + Float(descriptor.offset.width) * metresPerPoint,
                (Float(descriptor.anchor.y) - 0.5) * height - Float(descriptor.offset.height) * metresPerPoint,
                0
            ) - bounds.center * attachment.scale
            guard labelPosition.x.isFinite, labelPosition.y.isFinite, labelPosition.z.isFinite else {
                pivot.isEnabled = false
                continue
            }
            attachment.position = labelPosition
            attachment.components.set(ModelSortGroupComponent(
                group: descriptor.occlusion == .alwaysVisible ? .planarUIAlwaysInFront : .planarUIInline,
                order: 0
            ))
            pivot.isEnabled = true
        }
    }
}

private struct DioramaAnnotationAttachmentTarget: Component {}
#endif
