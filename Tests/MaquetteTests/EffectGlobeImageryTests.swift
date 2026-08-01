import CoreGraphics
import SwiftUI
import Testing
@testable import Maquette

/// The globe wears the active effect's imagery treatment, so the handoff dissolves a styled chunk
/// into a matching world rather than into photography.
@MainActor
@Suite("Effect globe imagery")
struct EffectGlobeImageryTests {

    @Test("The ink pass flattens the world into its band count")
    func inkFlattensTheWorld() throws {
        let pass = InkEffectPass(style: InkStyle(colorLevels: 4))
        let world = try gradient(width: 64, height: 32)
        let styled = try #require(pass.globeImagery(from: world))
        #expect(styled.width == world.width)
        #expect(styled.height == world.height)
        // A posterized gradient collapses to a handful of flat tones — far fewer than the 64
        // distinct greys that went in.
        let bands = try colours(of: styled)
        #expect(bands.count <= 8)
        #expect(bands.count >= 2)
    }

    @Test("The terraced pass bands the world by its step count")
    func terraceBandsTheWorld() throws {
        let pass = TerraceEffectPass(style: TerraceStyle(steps: .automatic(count: 5)))
        let world = try gradient(width: 64, height: 32)
        let styled = try #require(pass.globeImagery(from: world))
        let bands = try colours(of: styled)
        #expect(bands.count <= 8)
        #expect(bands.count >= 2)
    }

    @Test("The hologram pass remaps luma into its tint over near-black")
    func hologramTintsTheWorld() throws {
        let pass = HologramEffectPass(style: HologramStyle(tint: Color(red: 0, green: 1, blue: 1)))
        let world = try gradient(width: 16, height: 4)
        let styled = try #require(pass.globeImagery(from: world))
        for colour in try colours(of: styled) {
            // A cyan tint has no red to give, so every output pixel keeps red at zero while
            // green and blue ride the luma together.
            #expect(colour.x == 0)
            #expect(abs(Int(colour.y) - Int(colour.z)) <= 1)
        }
        // The darkest input maps to the floor, not to nothing: the sphere's silhouette survives.
        let darkest = try colours(of: styled).map { Int($0.y) }.min()
        #expect(try #require(darkest) > 0)
    }

    // MARK: - Helpers

    private func gradient(width: Int, height: Int) throws -> CGImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 255, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let value = UInt8(x * 255 / max(1, width - 1))
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
            }
        }
        let image = pixels.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        return try #require(image)
    }

    private func colours(of image: CGImage) throws -> Set<SIMD3<UInt8>> {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        #expect(drew)
        var found: Set<SIMD3<UInt8>> = []
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            found.insert(SIMD3(pixels[offset], pixels[offset + 1], pixels[offset + 2]))
        }
        return found
    }
}
