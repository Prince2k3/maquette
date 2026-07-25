import CoreGraphics
import Foundation
import RealityKit
import os

/// Fetches and decodes individual 3D Tiles content (GLB) into RealityKit entities.
public struct Tile3DLoader: Sendable {
    let provider: any Tiles3DProvider
    let ecefConverter: ECEFConverter
    /// Outline to cut tile geometry to as it loads, or `nil` to keep tiles whole.
    let clipPrism: BoundaryPrism?

    init(provider: any Tiles3DProvider, ecefConverter: ECEFConverter, clipPrism: BoundaryPrism? = nil) {
        self.provider = provider
        self.ecefConverter = ecefConverter
        self.clipPrism = clipPrism
    }

    private let logger = Logger(subsystem: "com.maquette", category: "Tile3DLoader")

    /// Loads a single tile's GLB content and creates a ModelEntity.
    /// - Parameters:
    ///   - uri: The content URI from the tile JSON.
    ///   - transform: The accumulated ECEF transform for this tile (Double precision).
    /// - Returns: A `ModelEntity` positioned in local coordinates, or `nil` if the tile uses unsupported features.
    @MainActor
    public func loadTile(uri: String, transform: simd_double4x4?) async throws -> ModelEntity? {
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
    public func loadTileFromData(_ data: Data, uri: String, transform: simd_double4x4?) async throws -> ModelEntity? {
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

        // Create material from texture if available
        let material: RealityKit.Material
        if let textureImage = parsed.textureImages.first {
            let texture = try await TextureResource(image: textureImage, options: .init(semantic: .color))
            var simpleMaterial = SimpleMaterial()
            simpleMaterial.color.texture = .init(texture)
            simpleMaterial.roughness = .float(0.8)
            simpleMaterial.metallic = .float(0.0)
            material = simpleMaterial
        } else {
            var simpleMaterial = SimpleMaterial()
            simpleMaterial.color.tint = .gray
            simpleMaterial.roughness = .float(0.9)
            material = simpleMaterial
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
        if let clipPrism {
            descriptors = Tiles3DClipper.clip(
                descriptors: parsed.meshDescriptors,
                placement: localTransform,
                to: clipPrism
            )
            guard !descriptors.isEmpty else {
                // Worth logging the geometry's position against the prism: a tileset whose tiles
                // are coarser than the diorama's radius will clip away entirely, which looks like
                // a rendering failure but is really a radius that is too small for the source.
                let translation = localTransform.columns.3
                logger.debug("""
                    Tile clipped away: \(uri.suffix(24)) \
                    local=(\(translation.x), \(translation.y), \(translation.z)) \
                    prism=[\(clipPrism.lowerBound.x)...\(clipPrism.upperBound.x)]
                    """)
                return nil
            }
            entityTransform = matrix_identity_float4x4
        } else {
            descriptors = parsed.meshDescriptors
            entityTransform = localTransform
        }

        let mesh = try MeshResource.generate(from: descriptors)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.transform = Transform(matrix: entityTransform)

        return entity
    }
}
