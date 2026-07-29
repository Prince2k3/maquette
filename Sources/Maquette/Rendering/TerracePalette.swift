import CoreGraphics
import Foundation
import RealityKit
import SwiftUI

/// Builds the colour strip a terraced chunk is painted from.
///
/// The whole terraced surface — every plateau and every riser — is one mesh drawn with one material,
/// and the colours are told apart by where a triangle samples this strip rather than by which
/// material it uses. So the strip has a column per elevation band and two rows: the lower one
/// (V ≈ 0.25) holds the flat tops, the upper one (V ≈ 0.75) the same colours darkened for the step
/// faces. `TerraceGeometry` writes those two V values and nothing else.
///
/// Every triangle samples a single point of it, so nothing here is ever interpolated across a
/// triangle: a plateau's three corners share a column, and a riser's three corners share a column.
/// The bands come out flat by construction rather than by filtering luck.
enum TerracePalette {
    /// Texels per band, so bilinear filtering samples a column's middle rather than its neighbours.
    private static let bandWidth = 8
    /// Two rows of tops and two of risers, which puts both V values a whole texel inside their half.
    private static let rowHeight = 2

    /// Renders a ramp into a band strip.
    ///
    /// - Parameters:
    ///   - colors: The ramp, lowest ground first. Interpolated across `count` bands, so the ramp's
    ///     length has nothing to do with how many steps the terrain is cut into.
    ///   - count: How many bands the ladder has.
    ///   - riserShade: What each band's colour is multiplied by on the step faces.
    @MainActor
    static func makeTexture(colors: [Color], count: Int, riserShade: Float) throws -> TextureResource {
        guard let image = makeImage(colors: colors, count: count, riserShade: riserShade) else {
            throw DioramaError.meshGenerationFailed(reason: "Failed to render terrace palette")
        }
        return try TextureResource(image: image, options: .init(semantic: .color))
    }

    /// Renders the strip into a `CGImage`. Separated from the texture so it can be exercised without
    /// a RealityKit device context, the same way `StrataTexture` is.
    static func makeImage(colors: [Color], count: Int, riserShade: Float) -> CGImage? {
        guard count > 0, !colors.isEmpty else { return nil }
        let ramp = colors.map { StrataTexture.rgbComponents(of: $0) }

        let width = count * bandWidth
        let height = rowHeight * 2
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
        let shade = max(0, min(1, riserShade))

        for band in 0..<count {
            let (r, g, b) = color(atBand: band, of: count, ramp: ramp)
            for column in (band * bandWidth)..<((band + 1) * bandWidth) {
                for row in 0..<height {
                    // `CGContext` rows run top-down and V runs bottom-up, so the strip's *first*
                    // rows are its high-V half — the risers.
                    let isRiser = row < rowHeight
                    let factor = isRiser ? shade : 1
                    let offset = (row * width + column) * 4
                    pixels[offset] = byte(r * factor)
                    pixels[offset + 1] = byte(g * factor)
                    pixels[offset + 2] = byte(b * factor)
                    pixels[offset + 3] = 255
                }
            }
        }

        return context.makeImage()
    }

    /// Where a band lands on the ramp.
    static func color(
        atBand band: Int,
        of count: Int,
        ramp: [(Float, Float, Float)]
    ) -> (Float, Float, Float) {
        guard let first = ramp.first, let last = ramp.last else { return (0.5, 0.5, 0.5) }
        guard ramp.count > 1, count > 1 else { return first }

        let position = Float(band) / Float(count - 1) * Float(ramp.count - 1)
        let lower = min(Int(position), ramp.count - 2)
        let fraction = position - Float(lower)
        guard lower + 1 < ramp.count else { return last }

        let a = ramp[lower]
        let b = ramp[lower + 1]
        return (
            a.0 + (b.0 - a.0) * fraction,
            a.1 + (b.1 - a.1) * fraction,
            a.2 + (b.2 - a.2) * fraction
        )
    }

    private static func byte(_ value: Float) -> UInt8 {
        UInt8(max(0, min(1, value)) * 255)
    }
}
