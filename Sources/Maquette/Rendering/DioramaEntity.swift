import Foundation
import RealityKit
import SwiftUI

/// Root entity that composes the complete diorama: terrain or 3D tiles, mask, and annotation anchors.
///
/// ```
/// DioramaEntity (root)
/// ├── TerrainEntity (mesh + satellite texture)  — OR —
/// ├── Tiles3DEntity (OGC 3D Tiles content)
/// ├── MaskEntity (circular boundary + pedestal)
/// └── AnnotationAnchors (positioned for SwiftUI attachments)
/// ```
@MainActor
public class DioramaEntity: Entity {
    /// The terrain sub-entity (used with raster tile pipeline).
    public private(set) var terrain: TerrainEntity?

    /// The 3D Tiles sub-entity (used with photorealistic pipeline).
    public private(set) var tiles3D: Tiles3DEntity?

    /// The water plane sub-entity (visible when terrain has sea-level areas).
    public private(set) var waterPlane: Entity?

    /// The mask/pedestal sub-entity.
    public private(set) var mask: Entity?

    /// Annotation anchor entities keyed by identifier.
    public private(set) var annotationAnchors: [String: Entity] = [:]

    /// Creates an empty diorama entity. Populate using the `set*` methods.
    public required init() {
        super.init()
        self.name = "Maquette"
    }

    /// Sets the terrain component of the diorama.
    public func setTerrain(_ terrainEntity: TerrainEntity) {
        self.terrain?.removeFromParent()
        self.terrain = terrainEntity
        addChild(terrainEntity)
    }

    /// Sets the 3D Tiles component of the diorama (alternative to terrain).
    public func setTiles3D(_ entity: Tiles3DEntity) {
        self.tiles3D?.removeFromParent()
        self.tiles3D = entity
        addChild(entity)
    }

    /// Sets the water plane component of the diorama.
    public func setWaterPlane(_ entity: Entity) {
        self.waterPlane?.removeFromParent()
        self.waterPlane = entity
        addChild(entity)
    }

    /// Sets the mask/pedestal component of the diorama.
    public func setMask(_ maskEntity: Entity) {
        self.mask?.removeFromParent()
        self.mask = maskEntity
        addChild(maskEntity)
    }

    /// Adds an annotation anchor at the specified 3D position.
    ///
    /// - Parameters:
    ///   - identifier: Unique identifier for this annotation.
    ///   - position: 3D position in the diorama's local coordinate space.
    public func addAnnotationAnchor(identifier: String, position: SIMD3<Float>) {
        let anchor = Entity()
        anchor.name = "Annotation_\(identifier)"
        anchor.position = position
        annotationAnchors[identifier] = anchor
        addChild(anchor)
    }

    /// Removes all annotation anchors.
    public func clearAnnotationAnchors() {
        for (_, anchor) in annotationAnchors {
            anchor.removeFromParent()
        }
        annotationAnchors.removeAll()
    }
}
