import CoreGraphics
import Foundation
import simd

/// Reads a terraced chunk's colours off the ground it was cut from.
///
/// A contour model is painted, and what it is painted is the place: canyon country comes out in
/// ochres, a forested valley in greens, water in blue. Handing that to the caller as a ramp makes it
/// a property of the *style* instead — one preset per biome, chosen by whoever set the diorama up,
/// and wrong the moment the chunk pans onto different ground. Measuring it is what makes the effect
/// one thing rather than a family of them.
///
/// The colour of a band is the average colour of the imagery *at that height*, which is why the
/// samples are taken at the surface's own vertices rather than over the image as a whole: a vertex is
/// the one place the mesh knows both a height and a texture coordinate, so the pairing is free and
/// exact. Everything else here exists to undo what averaging does to a photograph.
///
/// Core Graphics only, so it runs off the main actor and under test.
enum TerraceImagery {
    /// Rec. 601 luma, which is what "how bright is this" means throughout this file.
    private static let luma = SIMD3<Float>(0.299, 0.587, 0.114)

    /// The longest side the mosaic is redrawn to before sampling.
    ///
    /// A mosaic runs to a couple of thousand pixels a side, and every sample taken from it is about
    /// to be averaged with thousands of others — so drawing it down first costs a band's colour
    /// nothing and saves redrawing sixteen megabytes to read a few tens of thousands of pixels.
    private static let sampleExtent = 512

    /// How far the measured colours are pushed away from what the camera recorded.
    ///
    /// Both of these correct the same thing from two directions. Aerial imagery is hazy and muted to
    /// begin with, and averaging a whole band of it drags every band towards the same brown; left
    /// alone the ladder comes out as sixteen shades of mud, which reads as a badly lit model rather
    /// than a painted one.
    struct Recipe: Sendable, Equatable {
        /// Scales each band's distance from its own grey, so the hue the ground actually has survives
        /// the averaging.
        var saturation: Float
        /// Scales each band's distance from the ladder's mean brightness, so neighbouring steps stay
        /// told apart. This exaggerates a difference the ground has; it cannot invent one, and a
        /// genuinely uniform stretch of desert still comes out uniform.
        var contrast: Float
    }

    /// Returns one colour per band, or `nil` if nothing could be measured.
    ///
    /// - Parameters:
    ///   - image: The composited mosaic currently under the chunk.
    ///   - positions: The top surface's vertex positions, in diorama space.
    ///   - textureCoordinates: Those vertices' texture coordinates, one per position.
    ///   - bands: The ladder the chunk is being cut on.
    ///   - recipe: How far to push what is measured.
    static func palette(
        from image: CGImage,
        positions: [SIMD3<Float>],
        textureCoordinates: [SIMD2<Float>],
        bands: TerraceBands,
        recipe: Recipe
    ) -> [SIMD3<Float>]? {
        guard bands.count > 0,
              !positions.isEmpty,
              positions.count == textureCoordinates.count,
              image.width > 0, image.height > 0
        else { return nil }

        let scale = min(1, Float(sampleExtent) / Float(max(image.width, image.height)))
        let width = max(1, Int((Float(image.width) * scale).rounded()))
        let height = max(1, Int((Float(image.height) * scale).rounded()))
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        // Redrawn into a known layout rather than read through `dataProvider`, because the source is
        // whatever the tile provider's decoder produced and may be any component order or row padding
        // at all. Same reason `InkImagery` redraws.
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var totals = [SIMD3<Double>](repeating: .zero, count: bands.count)
        var counts = [Int](repeating: 0, count: bands.count)

        for index in positions.indices {
            let band = bands.paletteIndex(ofRung: bands.rung(of: positions[index].y))
            let uv = textureCoordinates[index]
            let column = Int((uv.x * Float(width)).rounded(.down))
            // V counts up from the image's southern edge and bitmap rows count down from its
            // northern one — the same flip `TerrainHeightField.textureCoordinate` applies, read back
            // the other way.
            let row = Int(((1 - uv.y) * Float(height)).rounded(.down))
            guard column >= 0, column < width, row >= 0, row < height else { continue }

            let offset = row * bytesPerRow + column * 4
            totals[band] += SIMD3(
                Double(pixels[offset]),
                Double(pixels[offset + 1]),
                Double(pixels[offset + 2])
            )
            counts[band] += 1
        }

        guard counts.contains(where: { $0 > 0 }) else { return nil }

        var colors = [SIMD3<Float>](repeating: .zero, count: bands.count)
        for band in colors.indices where counts[band] > 0 {
            colors[band] = SIMD3<Float>(totals[band] / Double(counts[band])) / 255
        }
        fillEmptyBands(&colors, counts: counts)
        exaggerate(&colors, recipe: recipe)
        return colors
    }

    /// Gives a band no vertex landed in the colour of the nearest one that did.
    ///
    /// Empty bands are ordinary rather than exceptional: `paletteIndex` clamps at both ends so ground
    /// panned in from outside the measured relief still has a colour, and a ladder cut across a cliff
    /// has rungs the terrain crosses without ever resting on. Left black they would band the model
    /// with stripes of a colour that is nowhere on the ground.
    private static func fillEmptyBands(_ colors: inout [SIMD3<Float>], counts: [Int]) {
        for band in colors.indices where counts[band] == 0 {
            var distance = 1
            while distance < colors.count {
                if band - distance >= 0, counts[band - distance] > 0 {
                    colors[band] = colors[band - distance]
                    break
                }
                if band + distance < colors.count, counts[band + distance] > 0 {
                    colors[band] = colors[band + distance]
                    break
                }
                distance += 1
            }
        }
    }

    /// The brightness the darkest band is lifted to if it falls below it.
    ///
    /// Deep forest and canyon shadow are genuinely almost black in aerial imagery, and pushing the
    /// contrast takes them the rest of the way. A band that lands there stops being a colour: it
    /// reads as unlit rather than as painted, and a model built out of sheets of card has no black
    /// card in it.
    private static let minimumTone: Float = 0.14

    /// Pushes tone away from the ladder's mean and chroma away from each band's own grey.
    ///
    /// Tone and chroma are pushed separately for the reason `InkImagery` bands them separately:
    /// scaling the three channels together turns a difference in brightness into a difference in
    /// colour, and a light patch of the same ground comes out a different hue from a dark one.
    private static func exaggerate(_ colors: inout [SIMD3<Float>], recipe: Recipe) {
        let lumas = colors.map { simd_dot($0, luma) }
        let mean = lumas.reduce(0, +) / Float(lumas.count)

        var tones = [Float](repeating: 0, count: colors.count)
        for band in colors.indices {
            tones[band] = mean + (lumas[band] - mean) * recipe.contrast
        }

        // Lifted together rather than clamped one at a time, so the gaps the contrast just opened
        // between the dark bands survive the lift instead of collapsing onto the floor.
        let lift = max(0, minimumTone - (tones.min() ?? 0))

        for band in colors.indices {
            let chroma = (colors[band] - SIMD3(repeating: lumas[band])) * recipe.saturation
            colors[band] = simd_clamp(SIMD3(repeating: tones[band] + lift) + chroma, .zero, .one)
        }
    }
}
