import Foundation
import os
import RealityKit
import SwiftUI

/// Root entity that composes the complete diorama: the terrain chunk or 3D tiles, an optional
/// display base, and annotation anchors.
///
/// ```
/// DioramaEntity (root)
/// ├── TerrainEntity (surface + cut walls + bottom)  — OR —
/// ├── Tiles3DEntity (OGC 3D Tiles content)
/// ├── WaterPlane (when the region reaches sea level)
/// ├── BaseEntity (optional plinth beneath the chunk)
/// └── AnnotationAnchors (positioned for SwiftUI attachments)
/// ```
///
/// ## Vertical convention
///
/// Diorama-space Y = 0 is the lowest terrain elevation in the region. The terrain surface rises
/// into positive Y and the chunk's earth mass extends into negative Y down to its base depth.
@MainActor
class DioramaEntity: Entity {
    /// The terrain sub-entity (used with raster tile pipeline).
    public private(set) var terrain: TerrainEntity?

    /// The 3D Tiles sub-entity (used with photorealistic pipeline).
    public private(set) var tiles3D: Tiles3DEntity?

    /// The extruded buildings standing on the chunk, if any were requested and fetched.
    private(set) var buildings: BuildingsEntity?

    /// The water plane sub-entity (visible when terrain has sea-level areas).
    public private(set) var waterPlane: Entity?

    /// The optional display base beneath the chunk.
    public private(set) var base: Entity?

    /// Marker entities keyed by identifier.
    public private(set) var markerEntities: [String: MarkerEntity] = [:]

    /// Polyline entities keyed by identifier.
    var polylineEntities: [String: ModelEntity] {
        overlayRenderer.records.filter { $0.value.input.shape.isLine }.mapValues(\.entity)
    }
    lazy var overlayRenderer = DioramaOverlayRenderer(root: self)
    private var pendingPanPlacement: (() -> Void)?
    var panPresentationCompletion: ((Bool) -> Void)?
    var isPanPresentationDeferred: Bool {
        terrain?.isPanPresentationDeferred == true || tiles3D?.isPanPresentationDeferred == true
    }

    /// Return the completion so callers drain queued input only after reconciliation is finished.
    func finishPanPresentation(applyPlacement: Bool = true) -> ((Bool) -> Void)? {
        // Photo tiles and rim own one atomic transaction. Overlay reconciliation cannot consume
        // its input-draining completion while preparation or commit callbacks are still running.
        guard tiles3D?.isPanPresentationDeferred != true else { return nil }
        terrain?.commitPanPresentation()
        let placement = pendingPanPlacement, completion = panPresentationCompletion
        pendingPanPlacement = nil; panPresentationCompletion = nil
        if applyPlacement { placement?() }
        return completion
    }

    /// The route preview entity, if active.
    public private(set) var routePreview: RoutePreviewEntity?

    /// Vertical midpoint of the chunk in diorama space.
    ///
    /// Because the chunk hangs below Y = 0 by its base depth and rises above it by the terrain's
    /// relief, orbiting a camera about Y = 0 would frame the chunk off-center. Use this instead.
    public var verticalCenter: Float {
        guard let terrain else { return 0 }
        return (terrain.maxSurfaceY - terrain.baseDepth) / 2
    }

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

    /// Sets the extruded buildings standing on the chunk.
    func setBuildings(_ entity: BuildingsEntity) {
        self.buildings?.removeFromParent()
        self.buildings = entity
        addChild(entity)
    }

    /// Sets the water plane component of the diorama.
    public func setWaterPlane(_ entity: Entity) {
        self.waterPlane?.removeFromParent()
        self.waterPlane = entity
        addChild(entity)
    }

    /// Sets the display base beneath the chunk.
    public func setBase(_ baseEntity: Entity) {
        self.base?.removeFromParent()
        self.base = baseEntity
        addChild(baseEntity)
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

    /// Removes all marker and polyline overlay entities.
    public func clearOverlays() {
        for (_, marker) in markerEntities {
            marker.removeFromParent()
        }
        markerEntities.removeAll()

        overlayRenderer.clear()

        appliedPins.removeAll()
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

    private static let logger = Logger(maquette: "DioramaEntity")

    /// What each overlay entity was last built from, keyed by its (suffixed) identifier — the
    /// evidence the reconciliation below diffs against.
    var selection: DioramaSelection?

    private var appliedPins: [String: (annotation: DioramaFeature, coordinate: Coordinate)] = [:]

    /// One leaf drawing operation, flattened out of a feature's (possibly multi-) geometry.
    private enum OverlayPlan {
        case pin(key: String, coordinate: Coordinate, annotation: DioramaFeature)
        case overlay(DioramaOverlayInput)
    }

    /// Materializes diorama content as 3D entities.
    ///
    /// What gets drawn is decided by each annotation's *geometry*, not by which case of a content
    /// enum it arrived in: a point becomes a `MarkerEntity` at the right terrain height, a line
    /// becomes a ribbon following the surface, and a multi-geometry becomes one entity per part.
    ///
    /// **Applied as a keyed diff, not a rebuild.** This runs on every pan step — the overlays ride
    /// the terrain, so their positions are re-projected as the ground slides — and it used to begin
    /// with `clearOverlays()`, tearing down and recreating every entity and material each time. Now
    /// an entity whose annotation is unchanged is *moved* (a marker keeps its entity, materials,
    /// and selection state; a ribbon keeps its entity and material and takes a fresh mesh for the
    /// new terrain heights), entities whose identities vanished are removed, and only genuinely new
    /// or restyled annotations build anything.
    ///
    /// - Parameters:
    ///   - content: The content group to materialize.
    ///   - proxy: Coordinate converter for geographic → 3D position mapping.
    ///   - physicalSize: The diorama's physical diameter for sizing and offset calculations.
    public func applyContent(
        _ content: DioramaContentGroup,
        using proxy: DioramaProxy,
        physicalSize: Float
    ) {
        // Small Y offset to prevent z-fighting with the terrain surface
        let polylineYOffset = physicalSize * 0.002

        var plans: [OverlayPlan] = []
        var routePreviewItem: DioramaRoutePreview?
        for item in content.items {
            switch item {
            case .annotation(let annotation):
                // SwiftUI labels are hosted by the platform, never also rendered as pins.
                if annotation.viewAnnotation != nil { continue }
                if case .circle(let center, let radius) = annotation.overlay {
                    plans.append(.overlay(.init(id: annotation.id, shape: .circle(center, radius), annotation: annotation)))
                    continue
                }
                if case .image(_, let bounds) = annotation.overlay {
                    plans.append(.overlay(.init(id: annotation.id, shape: .image(bounds), annotation: annotation)))
                    continue
                }
                plan(
                    annotation.feature.geometry,
                    annotation: annotation,
                    identifier: annotation.id,
                    into: &plans
                )
            case .routePreview(let preview):
                routePreviewItem = preview
            }
        }

        let overlays = plans.compactMap { plan -> DioramaOverlayInput? in
            if case .overlay(let input) = plan { return input }; return nil
        }
        let place: () -> Void = { [weak self] in
            self?.reconcilePins(plans, using: proxy, physicalSize: physicalSize)
            self?.applyRoutePreview(routePreviewItem, using: proxy, physicalSize: physicalSize, yOffset: polylineYOffset)
        }
        if isPanPresentationDeferred, !overlays.isEmpty {
            pendingPanPlacement = place
        } else {
            pendingPanPlacement = nil
            place()
        }
        overlayRenderer.apply(overlays, proxy: proxy, physicalSize: physicalSize)
    }

    /// Flattens one geometry into leaf plans, recursing into the multi- and collection forms.
    ///
    /// Parts of a multi-geometry are suffixed rather than sharing the feature's identifier, so a
    /// `MultiPoint` of ten places is ten entities that can each be replaced rather than nine that
    /// silently overwrite each other in `markerEntities`.
    private func plan(
        _ geometry: Geometry?,
        annotation: DioramaFeature,
        identifier: String,
        into plans: inout [OverlayPlan]
    ) {
        switch geometry {
        case nil:
            // A null geometry is valid GeoJSON (RFC 7946 §3.2) and means the feature has properties
            // but no place, so there is nothing to draw and nothing wrong.
            break

        case .point(let point):
            plans.append(.pin(key: identifier, coordinate: point.coordinate, annotation: annotation))

        case .multiPoint(let multiPoint):
            for (index, coordinate) in multiPoint.coordinates.enumerated() {
                plans.append(.pin(key: "\(identifier)#\(index)", coordinate: coordinate, annotation: annotation))
            }

        case .lineString(let line):
            plans.append(.overlay(.init(id: identifier, shape: .line(line.coordinates), annotation: annotation)))

        case .multiLineString(let multiLine):
            for (index, line) in multiLine.lineStrings.enumerated() {
                plans.append(.overlay(.init(id: "\(identifier)#\(index)", shape: .line(line.coordinates), annotation: annotation)))
            }

        case .polygon(let polygon):
            plans.append(.overlay(.init(id: identifier, shape: .polygon(polygon), annotation: annotation)))
        case .multiPolygon(let polygons):
            for (index, polygon) in polygons.polygons.enumerated() {
                plans.append(.overlay(.init(id: "\(identifier)#\(index)", shape: .polygon(polygon), annotation: annotation)))
            }

        case .geometryCollection(let geometries):
            for (index, child) in geometries.enumerated() {
                plan(child, annotation: annotation, identifier: "\(identifier)#\(index)", into: &plans)
            }
        }
    }

    private func reconcilePins(_ plans: [OverlayPlan], using proxy: DioramaProxy, physicalSize: Float) {
        var nextApplied = appliedPins
        var active = Set<String>()

        for plan in plans {
            guard case .pin(let key, let coordinate, let annotation) = plan else { continue }
            active.insert(key)

            // Residency and the outline can temporarily hide a pin without changing content
            // identity. Keep its last applied style until it can actually be rendered again.
            guard let position = proxy.position(for: coordinate, altitude: annotation.style.altitude) else {
                markerEntities[key]?.isEnabled = false
                continue
            }

            if let existing = markerEntities[key],
               appliedPins[key]?.annotation.style == annotation.style {
                // Same pin, new ground: move it. Keeps the entity, its materials, and its
                // selection state across every pan step.
                existing.position = position
            } else {
                let marker = MarkerEntity(tint: annotation.style.tint, physicalSize: physicalSize)
                addMarker(marker, identifier: key, position: position)
            }
            nextApplied[key] = (annotation, coordinate)
            let identity = DioramaMarkerIdentity(
                annotationID: annotation.selectionAnnotationID ?? annotation.id, tag: annotation.selectionTag
            )
            markerEntities[key]?.components.set(identity)
            let opacity = annotation.style.opacity
            markerEntities[key]?.isEnabled = opacity.isFinite && opacity > 0
            markerEntities[key]?.components.set(OpacityComponent(opacity: opacity.isFinite ? Float(max(0, min(1, opacity))) : 0))
            markerEntities[key]?.setSelected(selection?.isSelected(identity) ?? false)
        }

        // Identities that vanished from the content take their entities with them.
        for (key, marker) in markerEntities where !active.contains(key) {
            marker.removeFromParent()
            markerEntities[key] = nil
        }
        appliedPins = nextApplied.filter { active.contains($0.key) }
    }

    private func applyRoutePreview(
        _ preview: DioramaRoutePreview?,
        using proxy: DioramaProxy,
        physicalSize: Float,
        yOffset: Float
    ) {
        guard let preview else {
            clearRoutePreview()
            return
        }
        let points: [SIMD3<Float>] = preview.coordinates.compactMap {
            proxy.position(for: $0)
        }
        guard points.count >= 2 else {
            clearRoutePreview()
            return
        }
        do {
            let entity = try RoutePreviewEntity(
                routePoints: points,
                style: preview.style,
                physicalSize: physicalSize,
                yOffset: yOffset
            )
            setRoutePreview(entity)
        } catch {
            Self.logger.error("Failed to create route preview entity: \(error)")
        }
    }
}
