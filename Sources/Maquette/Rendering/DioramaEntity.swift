import Foundation
import os
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

    /// Marker entities keyed by identifier.
    public private(set) var markerEntities: [String: MarkerEntity] = [:]

    /// Polyline entities keyed by identifier.
    public private(set) var polylineEntities: [String: ModelEntity] = [:]

    /// The route preview entity, if active.
    public private(set) var routePreview: RoutePreviewEntity?

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

    // MARK: - Markers & Polylines

    /// Adds a marker entity at the specified 3D position.
    ///
    /// - Parameters:
    ///   - marker: The marker entity to add.
    ///   - identifier: Unique identifier for this marker.
    ///   - position: 3D position in the diorama's local coordinate space.
    public func addMarker(_ marker: MarkerEntity, identifier: String, position: SIMD3<Float>) {
        markerEntities[identifier]?.removeFromParent()
        marker.name = "Marker_\(identifier)"
        marker.position = position
        markerEntities[identifier] = marker
        addChild(marker)
    }

    /// Adds a polyline entity.
    ///
    /// - Parameters:
    ///   - polyline: The model entity representing the polyline ribbon mesh.
    ///   - identifier: Unique identifier for this polyline.
    public func addPolyline(_ polyline: ModelEntity, identifier: String) {
        polylineEntities[identifier]?.removeFromParent()
        polyline.name = "Polyline_\(identifier)"
        polylineEntities[identifier] = polyline
        addChild(polyline)
    }

    /// Removes all marker and polyline overlay entities.
    public func clearOverlays() {
        for (_, marker) in markerEntities {
            marker.removeFromParent()
        }
        markerEntities.removeAll()

        for (_, polyline) in polylineEntities {
            polyline.removeFromParent()
        }
        polylineEntities.removeAll()

        clearRoutePreview()
    }

    // MARK: - Route Preview

    /// Sets the route preview entity.
    public func setRoutePreview(_ entity: RoutePreviewEntity) {
        self.routePreview?.removeFromParent()
        self.routePreview = entity
        addChild(entity)
    }

    /// Removes the route preview entity.
    public func clearRoutePreview() {
        routePreview?.removeFromParent()
        routePreview = nil
    }

    // MARK: - Content Application

    private static let logger = Logger(subsystem: "com.maquette", category: "DioramaEntity")

    /// Materializes diorama content (markers, polylines, route previews) as 3D entities.
    ///
    /// Each marker becomes a `MarkerEntity` positioned at the correct terrain height.
    /// Each polyline becomes a flat ribbon mesh following the terrain surface.
    ///
    /// - Parameters:
    ///   - content: The content group to materialize.
    ///   - proxy: Coordinate converter for geographic → 3D position mapping.
    ///   - physicalDiameter: The diorama's physical diameter for sizing and offset calculations.
    public func applyContent(
        _ content: DioramaContentGroup,
        using proxy: DioramaProxy,
        physicalDiameter: Float
    ) {
        clearOverlays()

        // Small Y offset to prevent z-fighting with the terrain surface
        let polylineYOffset = physicalDiameter * 0.002

        for item in content.items {
            switch item {
            case .marker(let marker):
                guard let position = proxy.position(for: marker.coordinate) else { continue }
                let markerEntity = MarkerEntity(
                    tint: marker.tint,
                    physicalDiameter: physicalDiameter
                )
                addMarker(markerEntity, identifier: marker.title, position: position)

            case .polyline(let polyline):
                let points: [SIMD3<Float>] = polyline.coordinates.compactMap {
                    proxy.position(for: $0)
                }
                guard points.count >= 2 else { continue }

                guard let mesh = try? PolylineMeshGenerator.generateMesh(
                    from: points,
                    width: polyline.lineWidth,
                    yOffset: polylineYOffset
                ) else { continue }

                let material = DioramaMaterials.unlitMaterial(color: polyline.color)
                let polylineEntity = ModelEntity(mesh: mesh, materials: [material])
                addPolyline(polylineEntity, identifier: polyline.id)

            case .routePreview(let preview):
                let points: [SIMD3<Float>] = preview.coordinates.compactMap {
                    proxy.position(for: $0)
                }
                guard points.count >= 2 else { continue }

                do {
                    let entity = try RoutePreviewEntity(
                        routePoints: points,
                        style: preview.style,
                        physicalDiameter: physicalDiameter,
                        yOffset: polylineYOffset
                    )
                    setRoutePreview(entity)
                } catch {
                    Self.logger.error("Failed to create route preview entity: \(error)")
                }
            }
        }
    }
}
