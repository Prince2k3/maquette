import CoreGraphics
import Foundation
import Metal
import RealityKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Helpers for creating RealityKit materials used in diorama rendering.
enum DioramaMaterials {
    /// Creates a material textured with satellite imagery data.
    ///
    /// - Parameter imageData: Raw PNG or JPEG image data.
    /// - Returns: A `SimpleMaterial` with the image as its base color texture.
    @MainActor
    public static func satelliteTextureMaterial(from imageData: Data) throws -> SimpleMaterial {
        guard let texture = try? createTextureResource(from: imageData) else {
            throw DioramaError.meshGenerationFailed(reason: "Failed to create texture from satellite image data")
        }

        var material = SimpleMaterial()
        material.color.texture = .init(texture)
        material.roughness = .float(0.7)
        material.metallic = .float(0.0)
        return material
    }

    /// Wraps an already-composited image as a terrain surface material.
    ///
    /// Separated from the compositing so a rolling fetch can draw the mosaic off the main actor and
    /// only come back for the texture upload, which is the part that has to be here.
    @MainActor
    public static func satelliteMaterial(from image: CGImage) throws -> SimpleMaterial {
        let texture = try TextureResource(image: image, options: .init(semantic: .color))

        var material = SimpleMaterial()
        material.color.texture = .init(texture)
        material.roughness = .float(0.7)
        material.metallic = .float(0.0)
        return material
    }

    /// Draws satellite tiles into a single image covering the mosaic.
    ///
    /// Runs anywhere — it is Core Graphics only, with no RealityKit resource creation.
    public static func compositeSatelliteImage(
        tiles: [(x: Int, y: Int, data: Data)],
        minX: Int,
        minY: Int,
        tilesWide: Int,
        tilesTall: Int
    ) throws -> CGImage {
        guard let firstTile = tiles.first else {
            throw DioramaError.meshGenerationFailed(reason: "No satellite tiles to composite")
        }

        // Decode first tile to get tile dimensions
        guard let firstImage = cgImage(from: firstTile.data) else {
            throw DioramaError.meshGenerationFailed(reason: "Failed to decode first satellite tile")
        }

        let tileWidth = firstImage.width
        let tileHeight = firstImage.height
        let totalWidth = tilesWide * tileWidth
        let totalHeight = tilesTall * tileHeight

        // Create compositing context
        guard let context = CGContext(
            data: nil,
            width: totalWidth,
            height: totalHeight,
            bitsPerComponent: 8,
            bytesPerRow: totalWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw DioramaError.meshGenerationFailed(reason: "Failed to create compositing context")
        }

        // Draw each tile at its grid position
        for tile in tiles {
            guard let image = cgImage(from: tile.data) else { continue }
            let col = tile.x - minX
            let row = tile.y - minY
            // CGContext has origin at bottom-left, tiles have origin at top-left
            let x = col * tileWidth
            let y = (tilesTall - 1 - row) * tileHeight
            context.draw(image, in: CGRect(x: x, y: y, width: tileWidth, height: tileHeight))
        }

        guard let compositedImage = context.makeImage() else {
            throw DioramaError.meshGenerationFailed(reason: "Failed to create composited image")
        }
        return compositedImage
    }

    // MARK: - Chunk Materials

    /// Creates the material for a terrain chunk's cut walls.
    ///
    /// Strata walls are textured with a procedurally generated cross-section; solid walls are a
    /// flat color. Both are lit so the chunk's sides read as a physical object rather than a decal.
    ///
    /// - Parameter style: The wall style to realize.
    /// - Returns: A material, or `nil` when the style requests no walls.
    @MainActor
    public static func wallMaterial(for style: ChunkWallStyle) -> RealityKit.Material? {
        switch style {
        case .none:
            return nil

        case .solid(let color):
            return litMaterial(color: color, roughness: 0.9)

        case .strata(let palette):
            guard let texture = try? StrataTexture.makeTexture(palette: palette) else {
                // Fall back to the deepest band so a texture failure still reads as earth.
                let fallback = palette.bands.first?.color ?? Color(red: 0.35, green: 0.29, blue: 0.24)
                return litMaterial(color: fallback, roughness: 0.9)
            }
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(texture: .init(texture))
            material.roughness = .init(floatLiteral: 0.95)
            material.metallic = .init(floatLiteral: 0.0)
            return material
        }
    }

    /// Creates the material for a terrain chunk's bottom face.
    @MainActor
    public static func bottomMaterial(color: Color) -> RealityKit.Material {
        litMaterial(color: color, roughness: 1.0)
    }

    /// Creates a lit, non-metallic material with the given color.
    @MainActor
    public static func litMaterial(color: Color, roughness: Float) -> SimpleMaterial {
        var material = SimpleMaterial()
        #if canImport(UIKit)
        material.color.tint = UIColor(color)
        #elseif canImport(AppKit)
        material.color.tint = NSColor(color)
        #endif
        material.roughness = .float(roughness)
        material.metallic = .float(0.0)
        return material
    }

    /// Creates the material extruded buildings are drawn with.
    ///
    /// Lit, unlike the hologram's own surfaces: a block's whole job is to read as a volume, and four
    /// walls and a roof painted one flat color read as a silhouette instead. Culling stays on, since
    /// a building is a closed prism and its inside is never meant to be seen.
    ///
    /// - Parameters:
    ///   - color: The block color.
    ///   - opacity: How solid the blocks are, in `0...1`.
    ///
    /// `PhysicallyBasedMaterial` rather than the `SimpleMaterial` the rest of the chunk uses, only
    /// because `SimpleMaterial` exposes no `blending` and these need to be translucent under the
    /// hologram.
    @MainActor
    public static func buildingMaterial(color: Color, opacity: Float) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        #if canImport(UIKit)
        material.baseColor = .init(tint: UIColor(color))
        #elseif canImport(AppKit)
        material.baseColor = .init(tint: NSColor(color))
        #endif
        material.roughness = .init(floatLiteral: 0.85)
        material.metallic = .init(floatLiteral: 0)
        if opacity < 1 {
            material.blending = .transparent(opacity: .init(floatLiteral: max(0, opacity)))
        }
        return material
    }

    /// Creates an unlit material with the given SwiftUI color.
    ///
    /// Used for markers and polyline overlays that should not be affected by scene lighting.
    @MainActor
    public static func unlitMaterial(color: Color) -> UnlitMaterial {
        #if canImport(UIKit)
        var material = UnlitMaterial()
        material.color.tint = UIColor(color)
        return material
        #elseif canImport(AppKit)
        var material = UnlitMaterial()
        material.color.tint = NSColor(color)
        return material
        #endif
    }

    // MARK: - Effect Materials

    /// Creates the material a hologram's lines are drawn with.
    ///
    /// Unlit because the whole conceit is that the lines emit rather than reflect — a lit material
    /// would darken them wherever the terrain happened to face away from the scene's light. Culling
    /// is off because a ribbon lying on a slope is seen from underneath as readily as from above,
    /// and a line that vanished when the chunk was tilted would read as a rendering fault.
    ///
    /// - Parameters:
    ///   - color: The line color.
    ///   - opacity: How solid the line is, in `0...1`. The halo behind each line is the same
    ///     material at a low value, which is what stands in for a bloom pass: RealityKit exposes no
    ///     post-process bloom that works on all four platforms.
    @MainActor
    public static func hologramLineMaterial(color: Color, opacity: Float) -> UnlitMaterial {
        var material = unlitMaterial(color: color)
        material.faceCulling = .none
        if opacity < 1 {
            material.blending = .transparent(opacity: .init(floatLiteral: max(0, opacity)))
        }
        return material
    }

    /// Creates the material a hologram's body is painted with.
    ///
    /// Unlit for the same reason the lines are: the chunk is meant to read as projected light rather
    /// than as a lump of earth, and shading it would put the sun back into a scene that has none.
    @MainActor
    public static func hologramBodyMaterial(color: Color, opacity: Float) -> UnlitMaterial {
        var material = unlitMaterial(color: color)
        if opacity < 1 {
            material.blending = .transparent(opacity: .init(floatLiteral: max(0, opacity)))
        }
        return material
    }

    /// Creates the material the ink effect paints flat areas with — its block, its lines, its water.
    ///
    /// Unlit, which is the whole treatment in one word. The reference look gives an object its form
    /// entirely through the outlines drawn around it, and a shaded grey block would put a second,
    /// competing description of that form underneath — a gradient across a face the ink says is one
    /// flat colour. Culling stays on: unlike a hologram's ribbons, none of these surfaces is meant to
    /// be seen from behind.
    @MainActor
    public static func inkFlatMaterial(color: Color) -> UnlitMaterial {
        unlitMaterial(color: color)
    }

    /// Creates the material the ink effect draws lines with.
    ///
    /// Culling off, because a line traced along a fold in the terrain is looked at from both sides as
    /// the chunk is orbited, and a line that vanished at some angles would read as a rendering fault.
    @MainActor
    public static func inkLineMaterial(color: Color) -> UnlitMaterial {
        var material = unlitMaterial(color: color)
        material.faceCulling = .none
        return material
    }

    /// Wraps flattened imagery as the ink effect's terrain surface.
    ///
    /// Unlit for the same reason the rest of the effect is: the imagery has already been reduced to
    /// flat bands of colour, and lighting it would re-introduce exactly the continuous shading the
    /// posterizing took out.
    @MainActor
    public static func inkSurfaceMaterial(from image: CGImage) throws -> UnlitMaterial {
        let texture = try TextureResource(image: image, options: .init(semantic: .color))
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        return material
    }

    /// Wraps a terrace palette strip as the terraced effect's surface material.
    ///
    /// Lit, which is the one place this treatment parts company with the ink one. Ink describes form
    /// through the lines drawn around it and wants no shading competing with them; a terraced chunk
    /// describes form through the steps themselves, and it is shading that tells a plateau from the
    /// riser beside it when both are lit from the same side. Rough and non-metallic, so the result
    /// reads as card or clay rather than as moulded plastic.
    ///
    /// The sampling is nearest-neighbour with no mipmaps on purpose. The strip is a handful of texels
    /// across and every triangle samples a single point of it, so filtering could only ever blend a
    /// band into the one beside it — and a mip chain on an image this small collapses the entire
    /// palette to one colour within a couple of levels, which would drain the chunk of colour as the
    /// camera pulled back.
    @MainActor
    public static func terraceSurfaceMaterial(
        from image: CGImage,
        roughness: Float
    ) throws -> SimpleMaterial {
        let texture = try TextureResource(
            image: image,
            options: .init(semantic: .color, mipmapsMode: .none)
        )
        var material = SimpleMaterial()
        material.color = .init(tint: .white, texture: .init(texture, sampler: nearestSampler))
        material.roughness = .float(max(0, min(1, roughness)))
        material.metallic = .float(0)
        return material
    }

    /// A sampler that reads a texel rather than a blend of its neighbours.
    @MainActor
    private static var nearestSampler: MaterialParameters.Texture.Sampler {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .nearest
        descriptor.magFilter = .nearest
        descriptor.mipFilter = .notMipmapped
        return .init(descriptor)
    }

    // MARK: - Private

    private static func cgImage(from imageData: Data) -> CGImage? {
        #if canImport(UIKit)
        guard let uiImage = UIImage(data: imageData) else { return nil }
        return uiImage.cgImage
        #elseif canImport(AppKit)
        guard let nsImage = NSImage(data: imageData) else { return nil }
        return nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }

    @MainActor
    private static func createTextureResource(from imageData: Data) throws -> TextureResource? {
        #if canImport(UIKit)
        guard let uiImage = UIImage(data: imageData),
              let cgImage = uiImage.cgImage else { return nil }
        #elseif canImport(AppKit)
        guard let nsImage = NSImage(data: imageData),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #endif

        return try TextureResource(image: cgImage, options: .init(semantic: .color))
    }
}
