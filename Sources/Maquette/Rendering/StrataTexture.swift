import CoreGraphics
import Foundation
import RealityKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Builds the geological cross-section texture painted onto a terrain chunk's cut walls.
///
/// The texture is generated rather than shipped as an asset, so palettes are configurable and the
/// package keeps its zero-dependency, zero-resource footprint. Bands run horizontally, which means
/// the wall's horizontal texture coordinate barely matters — the layers read correctly regardless
/// of how the perimeter is parameterized.
enum StrataTexture {
    /// Width of the generated image. Narrow, because the pattern varies almost entirely
    /// along the vertical axis.
    private static let width = 96
    /// Height of the generated image. The vertical axis carries the strata detail.
    private static let height = 512

    /// Renders a strata palette into a tiling texture.
    ///
    /// - Parameter palette: The bands to render, ordered deepest to shallowest.
    /// - Returns: A texture whose V axis runs from the deepest layer at 0 to the surface at 1.
    @MainActor
    static func makeTexture(palette: StrataPalette) throws -> TextureResource {
        guard let image = makeImage(palette: palette) else {
            throw DioramaError.meshGenerationFailed(reason: "Failed to render strata texture")
        }
        return try TextureResource(image: image, options: .init(semantic: .color))
    }

    /// Renders the palette into a CGImage. Exposed separately so it can be exercised without
    /// a RealityKit device context.
    static func makeImage(palette: StrataPalette) -> CGImage? {
        let bands = palette.bands.filter { $0.thickness > 0 }
        guard !bands.isEmpty else { return nil }

        let totalThickness = bands.reduce(0) { $0 + $1.thickness }
        guard totalThickness > 0 else { return nil }

        // Boundary offset of each band, 0 at the deepest layer and 1 at the surface.
        var boundaries: [Float] = [0]
        var running: Float = 0
        for band in bands {
            running += band.thickness / totalThickness
            boundaries.append(running)
        }

        let components = bands.map { rgbComponents(of: $0.color) }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let buffer = context.data else {
            return nil
        }

        let pixels = buffer.bindMemory(to: UInt8.self, capacity: width * height * 4)

        for column in 0..<width {
            // A smooth, seamless horizontal wobble so band boundaries undulate rather than
            // running perfectly level. Frequencies are integers so the pattern tiles.
            let u = Float(column) / Float(width)
            let wobble = sin(u * 2 * .pi) * 0.55
                + sin(u * 6 * .pi + 1.7) * 0.30
                + sin(u * 14 * .pi + 4.2) * 0.15

            for row in 0..<height {
                // CGContext rows run top-down; V runs bottom-up, so flip.
                let v = 1 - Float(row) / Float(height - 1)

                let bandIndex = bandIndex(for: v, boundaries: boundaries, wobble: wobble, palette: palette)
                var (r, g, b) = components[bandIndex]

                // Fine grain, so large bands do not read as flat plastic.
                let grain = grainValue(column: column, row: row)
                r = clamp01(r + grain)
                g = clamp01(g + grain)
                b = clamp01(b + grain)

                let offset = (row * width + column) * 4
                pixels[offset] = UInt8(r * 255)
                pixels[offset + 1] = UInt8(g * 255)
                pixels[offset + 2] = UInt8(b * 255)
                pixels[offset + 3] = 255
            }
        }

        return context.makeImage()
    }

    /// Selects the band covering a vertical position, displaced by the horizontal wobble.
    private static func bandIndex(
        for v: Float,
        boundaries: [Float],
        wobble: Float,
        palette: StrataPalette
    ) -> Int {
        let bandCount = boundaries.count - 1
        for index in 0..<bandCount {
            let lower = boundaries[index]
            let upper = boundaries[index + 1]
            // Displace this band's upper boundary. Each band gets a different phase so the
            // layers do not move in lockstep.
            let thickness = upper - lower
            let phase = Float(index) * 2.4
            let displacement = wobble * cos(phase) * thickness * palette.irregularity
            if v < upper + displacement { return index }
        }
        return bandCount - 1
    }

    /// Deterministic per-pixel grain in roughly -0.03...0.03.
    private static func grainValue(column: Int, row: Int) -> Float {
        var hash = UInt32(truncatingIfNeeded: column &* 73_856_093 ^ row &* 19_349_663)
        hash ^= hash >> 13
        hash = hash &* 1_274_126_177
        hash ^= hash >> 16
        return (Float(hash % 1000) / 1000 - 0.5) * 0.06
    }

    private static func clamp01(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    /// Extracts RGB components from a SwiftUI color.
    static func rgbComponents(of color: Color) -> (Float, Float, Float) {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Float(r), Float(g), Float(b))
        #elseif canImport(AppKit)
        let converted = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        return (
            Float(converted.redComponent),
            Float(converted.greenComponent),
            Float(converted.blueComponent)
        )
        #else
        return (0.5, 0.4, 0.3)
        #endif
    }
}
