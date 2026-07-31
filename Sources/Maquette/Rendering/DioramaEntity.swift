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
public class DioramaEntity: Entity {
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
    public private(set) var polylineEntities: [String: ModelEntity] = [:]

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

    private static let logger = Logger(maquette: "DioramaEntity")

    /// Materializes diorama content as 3D entities.
    ///
    /// What gets drawn is decided by each annotation's *geometry*, not by which case of a content
    /// enum it arrived in: a point becomes a `MarkerEntity` at the right terrain height, a line
    /// becomes a ribbon following the surface, and a multi-geometry becomes one entity per part.
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
            case .annotation(let annotation):
                draw(
                    annotation.feature.geometry,
                    style: annotation.style,
                    identifier: annotation.id,
                    using: proxy,
                    physicalDiameter: physicalDiameter,
                    yOffset: polylineYOffset
                )

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

    /// Draws one geometry, recursing into the multi- and collection forms.
    ///
    /// Parts of a multi-geometry are suffixed rather than sharing the feature's identifier, so a
    /// `MultiPoint` of ten places is ten entities that can each be replaced rather than nine that
    /// silently overwrite each other in `markerEntities`.
    private func draw(
        _ geometry: Geometry?,
        style: AnnotationStyle,
        identifier: String,
        using proxy: DioramaProxy,
        physicalDiameter: Float,
        yOffset: Float
    ) {
        switch geometry {
        case nil:
            // A null geometry is valid GeoJSON (RFC 7946 §3.2) and means the feature has properties
            // but no place, so there is nothing to draw and nothing wrong.
            break

        case .point(let point):
            addPin(
                at: point.coordinate,
                style: style,
                identifier: identifier,
                using: proxy,
                physicalDiameter: physicalDiameter
            )

        case .multiPoint(let multiPoint):
            for (index, coordinate) in multiPoint.coordinates.enumerated() {
                addPin(
                    at: coordinate,
                    style: style,
                    identifier: "\(identifier)#\(index)",
                    using: proxy,
                    physicalDiameter: physicalDiameter
                )
            }

        case .lineString(let line):
            addRibbon(
                along: line.coordinates,
                style: style,
                identifier: identifier,
                using: proxy,
                yOffset: yOffset
            )

        case .multiLineString(let multiLine):
            for (index, line) in multiLine.lineStrings.enumerated() {
                addRibbon(
                    along: line.coordinates,
                    style: style,
                    identifier: "\(identifier)#\(index)",
                    using: proxy,
                    yOffset: yOffset
                )
            }

        case .polygon, .multiPolygon:
            // Deliberately not drawn yet rather than approximated by its outline: a filled region
            // is a different rendering problem — it has to be clipped to the chunk and draped on
            // the surface — and tracing the ring instead would look like a feature rather than a
            // gap. Logged so a caller whose polygons vanish can tell which of the two this is.
            Self.logger.debug(
                "Skipped annotation \(identifier, privacy: .public): polygons are not drawn yet"
            )

        case .geometryCollection(let geometries):
            for (index, child) in geometries.enumerated() {
                draw(
                    child,
                    style: style,
                    identifier: "\(identifier)#\(index)",
                    using: proxy,
                    physicalDiameter: physicalDiameter,
                    yOffset: yOffset
                )
            }
        }
    }

    private func addPin(
        at coordinate: Coordinate,
        style: AnnotationStyle,
        identifier: String,
        using proxy: DioramaProxy,
        physicalDiameter: Float
    ) {
        guard let position = proxy.position(for: coordinate, altitude: style.altitude) else {
            return
        }
        let marker = MarkerEntity(tint: style.tint, physicalDiameter: physicalDiameter)
        addMarker(marker, identifier: identifier, position: position)
    }

    private func addRibbon(
        along coordinates: [Coordinate],
        style: AnnotationStyle,
        identifier: String,
        using proxy: DioramaProxy,
        yOffset: Float
    ) {
        // Vertices the diorama has no ground for are dropped, which welds the ribbon across the
        // gap rather than breaking it in two. That is the behaviour the polyline had, and it is
        // right for a line that clips the outline's corner; a line that leaves the chunk and
        // returns wants splitting instead, and needs the clip that polygons are waiting on.
        let points: [SIMD3<Float>] = coordinates.compactMap {
            proxy.position(for: $0, altitude: style.altitude)
        }
        guard points.count >= 2 else { return }

        guard let mesh = try? PolylineMeshGenerator.generateMesh(
            from: points,
            width: style.lineWidth,
            yOffset: yOffset
        ) else { return }

        let material = DioramaMaterials.unlitMaterial(color: style.tint)
        addPolyline(ModelEntity(mesh: mesh, materials: [material]), identifier: identifier)
    }
}
