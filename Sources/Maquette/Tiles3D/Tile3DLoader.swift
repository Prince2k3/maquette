import CoreGraphics
import Foundation
import RealityKit
import os

/// Fetches and decodes individual 3D Tiles content (GLB) into RealityKit entities.
public struct Tile3DLoader: Sendable {
    let provider: any Tiles3DProvider
    let ecefConverter: ECEFConverter
    /// Outline to cut tile geometry to as it loads, or `nil` to keep tiles whole.
    ///
    /// Moves when the diorama pans, so tiles arriving mid-pan are cut where the outline is now
    /// rather than where it started.
    var clipPrism: BoundaryPrism?
    /// Whether to hand back each tile's geometry as it arrived, so a moved outline can re-cut it.
    var retainsSourceGeometry: Bool

    init(
        provider: any Tiles3DProvider,
        ecefConverter: ECEFConverter,
        clipPrism: BoundaryPrism? = nil,
        retainsSourceGeometry: Bool = false
    ) {
        self.provider = provider
        self.ecefConverter = ecefConverter
        self.clipPrism = clipPrism
        self.retainsSourceGeometry = retainsSourceGeometry
    }

    /// A tile turned into something drawable, with whatever is needed to cut it again.
    public struct LoadedTile {
        /// The tile's geometry, already cut to the outline.
        public let entity: ModelEntity
        /// The geometry before the cut, present only when the diorama can pan.
        let source: Tiles3DSourceGeometry?
    }

    private let logger = Logger(subsystem: "com.maquette", category: "Tile3DLoader")

    /// Loads a single tile's GLB content and creates a ModelEntity.
    /// - Parameters:
    ///   - uri: The content URI from the tile JSON.
    ///   - transform: The accumulated ECEF transform for this tile (Double precision).
    /// - Returns: A `ModelEntity` positioned in local coordinates, or `nil` if the tile uses unsupported features.
    @MainActor
    public func loadTile(uri: String, transform: simd_double4x4?) async throws -> LoadedTile? {
        let data = try await provider.fetchTileContent(uri: uri)
        return try await loadTileFromData(data, uri: uri, transform: transform)
    }

    /// Loads a tile from pre-fetched binary data (GLB/b3dm).
    /// - Parameters:
    ///   - data: Raw GLB or b3dm file data.
    ///   - uri: The content URI (for logging).
    ///   - transform: The accumulated ECEF transform for this tile (Double precision).
    /// - Returns: A `ModelEntity` positioned in local coordinates, or `nil` if the tile uses unsupported features.
    @MainActor
    public func loadTileFromData(_ data: Data, uri: String, transform: simd_double4x4?) async throws -> LoadedTile? {
        let parsed: GLBParser.ParsedTile
        do {
            parsed = try GLBParser.parse(data)
        } catch DioramaError.unsupportedTileFormat {
            logger.info("Skipping Draco-compressed tile: \(uri)")
            return nil
        }

        guard !parsed.meshDescriptors.isEmpty else {
            logger.warning("Tile has no mesh descriptors: \(uri)")
            return nil
        }

        // Photogrammetry arrives with lighting already baked into its imagery, and Google's tiles
        // declare `KHR_materials_unlit` as *required* for exactly that reason. They also ship no
        // NORMAL attribute, so a lit material has nothing to shade with: the surface renders black
        // wherever the substituted normal faces away from whatever light the scene happens to have.
        let material: RealityKit.Material
        if let textureImage = parsed.textureImages.first {
            let texture = try await TextureResource(image: textureImage, options: .init(semantic: .color))
            var unlit = UnlitMaterial()
            unlit.color = .init(texture: .init(texture))
            material = unlit
        } else {
            material = UnlitMaterial(color: .gray)
        }

        // Compose the full ECEF transform:
        //   accumulated tile tree transform × GLB root node transform
        // For Google 3D Tiles, the accumulated tile transform is identity (no
        // per-tile transforms in the JSON) and the GLB root node contains the
        // actual ECEF position. Previously we used `transform ?? parsed.transformDouble`
        // which discarded the GLB transform when an accumulated transform was passed in.
        let accumulated = transform ?? simd_double4x4(diagonal: .one)

        // Google 3D Tiles stores ECEF positions in glTF Y-up convention:
        //   glTF (x, y, z) = ECEF (x, z, -y)
        // Detect this by checking if the node transform has a large ECEF-scale
        // translation (Earth surface ≈ 6.37M meters). Local/identity transforms
        // (e.g., b3dm/CESIUM_RTC) have small translations and don't need conversion.
        let nodeTranslation = SIMD3<Double>(
            parsed.transformDouble.columns.3.x,
            parsed.transformDouble.columns.3.y,
            parsed.transformDouble.columns.3.z
        )
        let glbTransform: simd_double4x4
        if simd_length(nodeTranslation) > 1_000_000 {
            // Y-up ECEF → Z-up ECEF: (x, y, z) → (x, -z, y)
            let yUpToZUp = simd_double4x4(
                SIMD4<Double>(1, 0, 0, 0),
                SIMD4<Double>(0, 0, 1, 0),
                SIMD4<Double>(0, -1, 0, 0),
                SIMD4<Double>(0, 0, 0, 1)
            )
            glbTransform = yUpToZUp * parsed.transformDouble
        } else {
            glbTransform = parsed.transformDouble
        }

        // If CESIUM_RTC is present, mesh vertices are small offsets from the RTC center.
        // Prepend the RTC center as a translation so the final ECEF position is correct.
        let ecefTransform: simd_double4x4
        if let rtcCenter = parsed.rtcCenter {
            var rtcTranslation = simd_double4x4(diagonal: .one)
            rtcTranslation.columns.3 = SIMD4<Double>(rtcCenter.x, rtcCenter.y, rtcCenter.z, 1)
            ecefTransform = accumulated * rtcTranslation * glbTransform
        } else {
            ecefTransform = accumulated * glbTransform
        }

        let localTransform = ecefConverter.ecefTransformToLocal(ecefTransform)

        logger.debug("Transform \(uri.suffix(30)): ecef=(\(String(format: "%.1f", ecefTransform.columns.3.x)), \(String(format: "%.1f", ecefTransform.columns.3.y)), \(String(format: "%.1f", ecefTransform.columns.3.z))) local=(\(String(format: "%.3f", localTransform.columns.3.x)), \(String(format: "%.3f", localTransform.columns.3.y)), \(String(format: "%.3f", localTransform.columns.3.z)))")

        // Clipping bakes the placement into the vertices, because a prism that stands vertical in
        // diorama space would be tilted in the tile's own rotated space. The entity then carries
        // no transform of its own.
        let descriptors: [MeshDescriptor]
        let entityTransform: simd_float4x4
        var cutEdges: [Tiles3DCutEdge] = []
        // Kept before the clip, since the clip is what throws the original away. Built from the
        // parsed geometry rather than the clipped result so a pan can cut a tile somewhere it was
        // never cut before.
        let source = retainsSourceGeometry && clipPrism != nil
            ? Tiles3DSourceGeometry(
                descriptors: parsed.meshDescriptors,
                placement: localTransform,
                material: material
            )
            : nil
        if let clipPrism {
            let clipped = Tiles3DClipper.clip(
                descriptors: parsed.meshDescriptors,
                placement: localTransform,
                to: clipPrism
            )
            descriptors = clipped.descriptors
            cutEdges = clipped.cutEdges
            if descriptors.isEmpty {
                // Worth logging the geometry's position against the prism: a tileset whose tiles
                // are coarser than the diorama's radius will clip away entirely, which looks like
                // a rendering failure but is really a radius that is too small for the source.
                let translation = localTransform.columns.3
                logger.debug("""
                    Tile clipped away: \(uri.suffix(24)) \
                    local=(\(translation.x), \(translation.y), \(translation.z)) \
                    prism=[\(clipPrism.lowerBound.x)...\(clipPrism.upperBound.x)]
                    """)
                // On a fixed diorama nothing will ever bring this tile back, so the caller is told
                // it is empty and stops asking. When the diorama can pan it is the opposite: the
                // tile is just outside the outline *for now*, and panning towards it is precisely
                // how it comes into view. Discarding it would leave a permanent hole in that
                // direction, so it is kept — geometry and all, minus anything to draw.
                guard let source else { return nil }
                let placeholder = ModelEntity()
                placeholder.isEnabled = false
                return LoadedTile(entity: placeholder, source: source)
            }
            entityTransform = matrix_identity_float4x4
        } else {
            descriptors = parsed.meshDescriptors
            entityTransform = localTransform
        }

        let mesh = try MeshResource.generate(from: descriptors)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.transform = Transform(matrix: entityTransform)

        // Carried on the tile so the cut wall can be rebuilt from whatever is currently visible.
        if !cutEdges.isEmpty {
            _ = Tiles3DCutEdgeRegistration.perform
            entity.components.set(Tiles3DCutEdgeComponent(edges: cutEdges))
        }

        return LoadedTile(entity: entity, source: source)
    }
}
