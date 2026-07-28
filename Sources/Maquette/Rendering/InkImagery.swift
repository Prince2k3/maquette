import CoreGraphics
import Foundation
import simd

/// Flattens satellite imagery into the ink effect's cel-shaded fills.
///
/// The reference look is drawn, not photographed: each region of ground is one flat colour with a
/// hard edge against the next. Real aerial imagery is the opposite — continuous tone, noisy at every
/// scale — so it is reduced in two steps, and both are needed. Averaging over patches removes the
/// noise but leaves a gradient; quantizing the result to a handful of levels per channel is what
/// turns that gradient into bands with edges. Quantizing alone would band the noise instead of the
/// image and come out speckled.
///
/// Posterizing the real imagery rather than inventing a palette is deliberate. Painting sand, grass
/// and rock from a biome table would match the reference more closely and would stop the chunk being
/// the place it is, which is the whole premise of the library. Flattened imagery still reads as this
/// stretch of ground.
///
/// Core Graphics only, so it runs off the main actor and under test.
enum InkImagery {
    /// Rec. 601 luma, which is what "how bright is this" means throughout this file.
    private static let luma = SIMD3<Float>(0.299, 0.587, 0.114)

    /// The reduction applied to a source mosaic.
    struct Recipe {
        /// Source pixels per flat patch, along each axis. 1 leaves detail untouched.
        var patchSize: Int
        /// How many bands of tone the ground is reduced to. Lower is flatter; below about three the
        /// ground stops being legible as ground.
        var levels: Int
        /// Scales each patch's distance from its own grey. Drawn art is more saturated than aerial
        /// photography, which is muted by haze and by averaging.
        var saturation: Float
    }

    /// The brightness the darkest and lightest bands are pinned to, as fractions of full scale.
    ///
    /// Measured from the imagery rather than assumed, because a band grid spread evenly over black
    /// to white is the wrong grid for a photograph: aerial imagery of ordinary ground lives between
    /// roughly a quarter and a half brightness, so five even bands put nearly all of it in one and
    /// the ink effect comes out as a single flat slab.
    ///
    /// Carried between refreshes rather than re-measured, for the reason the wall texture's vertical
    /// reference and the elevation baseline are frozen at generation: a roll brings in new tiles,
    /// re-measuring would shift the range, and every band in the picture would change colour at once
    /// while the ground itself had barely moved.
    struct Tones: Sendable, Equatable {
        var low: Float
        var high: Float
    }

    /// Returns `image` reduced to flat bands of colour, and the tonal range it was banded against.
    ///
    /// - Parameter tones: The range to band against, or `nil` to measure it from this image. Pass
    ///   back the returned value on subsequent calls so the palette holds still across a roll.
    /// - Throws: ``DioramaError/meshGenerationFailed(reason:)`` if the image cannot be read into a
    ///   bitmap — the same failure mode, and the same error, as compositing the mosaic in the first
    ///   place.
    static func posterize(
        _ image: CGImage,
        recipe: Recipe,
        tones: Tones? = nil
    ) throws -> (image: CGImage, tones: Tones) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            throw DioramaError.meshGenerationFailed(reason: "Cannot posterize an empty image")
        }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        var measured = Tones(low: 0, high: 1)

        // Redrawn into a known layout rather than read through `dataProvider`, because the source is
        // whatever the tile provider's decoder produced and may be any component order or row
        // padding at all.
        let result: CGImage? = pixels.withUnsafeMutableBytes { raw -> CGImage? in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }

            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            measured = tones ?? range(raw, width: width, height: height, bytesPerRow: bytesPerRow)
            flatten(
                raw,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                recipe: recipe,
                tones: measured
            )
            return context.makeImage()
        }

        guard let result else {
            throw DioramaError.meshGenerationFailed(reason: "Failed to create posterizing context")
        }
        return (result, measured)
    }

    /// The image's own tonal range, ignoring the extreme few per cent at each end.
    ///
    /// Percentiles rather than the outright darkest and lightest pixel, because one specular
    /// highlight off water or one black gap between tiles would otherwise stretch the range to the
    /// full scale and undo the whole point of measuring it.
    private static func range(
        _ pixels: UnsafeMutableRawBufferPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> Tones {
        // Sampled rather than exhaustive: a mosaic runs to several thousand pixels a side, and a
        // percentile of a quarter of the pixels is the same percentile.
        let step = 2
        var histogram = [Int](repeating: 0, count: 256)
        var samples = 0

        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let offset = y * bytesPerRow + x * 4
                let colour = SIMD3<Float>(
                    Float(pixels[offset]),
                    Float(pixels[offset + 1]),
                    Float(pixels[offset + 2])
                )
                let bin = Int(simd_dot(colour, luma).rounded())
                histogram[min(255, max(0, bin))] += 1
                samples += 1
            }
        }
        guard samples > 0 else { return Tones(low: 0, high: 1) }

        let tail = max(1, samples / 50)
        var low = 0
        var high = 255
        var running = 0
        for bin in 0..<256 {
            running += histogram[bin]
            if running >= tail { low = bin; break }
        }
        running = 0
        for bin in stride(from: 255, through: 0, by: -1) {
            running += histogram[bin]
            if running >= tail { high = bin; break }
        }

        // A flat image has no range to stretch, and dividing by one would amplify its noise into
        // bands of pure black and white.
        guard high - low > 8 else { return Tones(low: 0, high: 1) }
        return Tones(low: Float(low) / 255, high: Float(high) / 255)
    }

    /// Averages each patch, snaps its brightness to a band, and paints the band back in the patch's
    /// own hue.
    ///
    /// Banding the brightness rather than each channel separately is what keeps this from coming out
    /// speckled. Quantizing red, green and blue independently splits a near-grey patch whose channels
    /// straddle a band edge into a fully saturated colour, so a stretch of even ground turns
    /// confetti — and the eye reads those pixels as noise rather than as the flat fills the reference
    /// is made of. Tone is banded; hue rides along.
    ///
    /// In place, over the whole buffer, so nothing here allocates per patch.
    private static func flatten(
        _ pixels: UnsafeMutableRawBufferPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        recipe: Recipe,
        tones: Tones
    ) {
        let patch = max(1, recipe.patchSize)
        let levels = max(2, recipe.levels)
        // Snapping to `levels` bands means `levels - 1` gaps between the extremes, so a band index
        // scaled this way puts the darkest band at 0 and the brightest at 255 rather than leaving
        // white unreachable — a mosaic of snow that never quite reaches white looks dirty.
        let quantizer = Float(levels - 1)
        let span = max(1e-3, tones.high - tones.low)

        for patchY in stride(from: 0, to: height, by: patch) {
            let rowEnd = min(patchY + patch, height)
            for patchX in stride(from: 0, to: width, by: patch) {
                let columnEnd = min(patchX + patch, width)

                var totals = SIMD3<Int>.zero
                var count = 0
                for y in patchY..<rowEnd {
                    for x in patchX..<columnEnd {
                        let offset = y * bytesPerRow + x * 4
                        totals &+= SIMD3(
                            Int(pixels[offset]),
                            Int(pixels[offset + 1]),
                            Int(pixels[offset + 2])
                        )
                        count += 1
                    }
                }
                guard count > 0 else { continue }

                let colour = SIMD3<Float>(totals) / (Float(count) * 255)
                let grey = simd_dot(colour, luma)

                let normalized = simd_clamp((grey - tones.low) / span, 0, 1)
                let banded = (normalized * quantizer).rounded(.toNearestOrAwayFromZero) / quantizer

                // The hue is the patch's own, carried across as an offset from its grey and pushed
                // outward. Banded on a finer grid than the tone: on the tone's own grid, ordinary
                // ground rounds to no offset at all and the whole chunk comes out monochrome.
                let chromaGrid = quantizer * 3
                var chroma = (colour - SIMD3(repeating: grey)) * recipe.saturation
                chroma = (chroma * chromaGrid).rounded(.toNearestOrAwayFromZero) / chromaGrid

                let flat = simd_clamp(SIMD3(repeating: banded) + chroma, .zero, .one)
                let bytes = SIMD3<UInt8>(simd_clamp(flat * 255, .zero, SIMD3(repeating: 255)))
                for y in patchY..<rowEnd {
                    for x in patchX..<columnEnd {
                        let offset = y * bytesPerRow + x * 4
                        pixels[offset] = bytes.x
                        pixels[offset + 1] = bytes.y
                        pixels[offset + 2] = bytes.z
                    }
                }
            }
        }
    }
}
