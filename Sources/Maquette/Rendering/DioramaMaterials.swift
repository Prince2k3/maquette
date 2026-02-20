import Foundation
import RealityKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Helpers for creating RealityKit materials used in diorama rendering.
public enum DioramaMaterials {
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

    /// Creates a material from multiple satellite tile images composited into a single texture.
    ///
    /// - Parameters:
    ///   - tiles: Array of tile positions and their image data.
    ///   - minX: Minimum tile X coordinate.
    ///   - minY: Minimum tile Y coordinate.
    ///   - tilesWide: Number of tiles horizontally.
    ///   - tilesTall: Number of tiles vertically.
    /// - Returns: A `SimpleMaterial` with the composited satellite texture.
    @MainActor
    public static func compositeSatelliteMaterial(
        tiles: [(x: Int, y: Int, data: Data)],
        minX: Int,
        minY: Int,
        tilesWide: Int,
        tilesTall: Int
    ) throws -> SimpleMaterial {
        guard let firstTile = tiles.first else {
            throw DioramaError.meshGenerationFailed(reason: "No satellite tiles to composite")
        }

        // If single tile, use the simple path
        if tiles.count == 1 {
            return try satelliteTextureMaterial(from: firstTile.data)
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

        let texture = try TextureResource(image: compositedImage, options: .init(semantic: .color))

        var material = SimpleMaterial()
        material.color.texture = .init(texture)
        material.roughness = .float(0.7)
        material.metallic = .float(0.0)
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
