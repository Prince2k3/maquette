import CoreGraphics
import Foundation
import RealityKit
import os

/// Fetches and decodes individual 3D Tiles content (GLB) into RealityKit entities.
public struct Tile3DLoader: Sendable {
    let provider: any Tiles3DProvider
    let ecefConverter: ECEFConverter

    private let logger = Logger(subsystem: "com.maquette", category: "Tile3DLoader")

    /// Loads a single tile's GLB content and creates a ModelEntity.
    /// - Parameters:
    ///   - uri: The content URI from the tile JSON.
    ///   - transform: The accumulated ECEF transform for this tile.
    /// - Returns: A `ModelEntity` positioned in local coordinates, or `nil` if the tile uses unsupported features.
    @MainActor
    public func loadTile(uri: String, transform: simd_float4x4?) async throws -> ModelEntity? {
        let data = try await provider.fetchTileContent(uri: uri)

        let parsed: GLBParser.ParsedTile
        do {
            parsed = try GLBParser.parse(data)
        } catch DioramaError.unsupportedTileFormat {
            logger.info("Skipping Draco-compressed tile: \(uri)")
            return nil
        }

        guard let firstDescriptor = parsed.meshDescriptors.first else {
            logger.warning("Tile has no mesh descriptors: \(uri)")
            return nil
        }

        let mesh = try MeshResource.generate(from: [firstDescriptor])

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

        let entity = ModelEntity(mesh: mesh, materials: [material])

        // Apply ECEF-to-local transform
        let tileTransform = transform ?? parsed.transform
        let localTransform = ecefConverter.ecefTransformToLocal(tileTransform)
        entity.transform = Transform(matrix: localTransform)

        return entity
    }
}
