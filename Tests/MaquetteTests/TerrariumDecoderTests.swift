import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Maquette

@Suite("Terrarium Decoder Tests")
struct TerrariumDecoderTests {

    @Test("A known Terrarium pixel decodes to its elevation")
    func knownPixelDecodes() throws {
        // 1000 m: raw = 33768 = 0x83E8 → r 0x83, g 0xE8.
        let png = TerrainRollerTests.terrariumPNG(elevation: 1000, size: 4)
        let grid = try TerrariumDecoder.decodeElevation(from: png)

        #expect(grid.width == 4)
        #expect(grid.height == 4)
        for value in grid.values {
            #expect(abs(value - 1000) < 0.5)
        }
    }

    @Test("Below-sea-level elevations decode negative")
    func negativeElevationDecodes() throws {
        let png = TerrainRollerTests.terrariumPNG(elevation: -420, size: 2)
        let grid = try TerrariumDecoder.decodeElevation(from: png)
        for value in grid.values {
            #expect(abs(value - (-420)) < 0.5)
        }
    }

    @Test("The grid's stored extremes match its values")
    func extremesAreMeasured() throws {
        let png = TerrainRollerTests.terrariumPNG(elevation: 250, size: 8)
        let grid = try TerrariumDecoder.decodeElevation(from: png)
        #expect(grid.minElevation == grid.values.min())
        #expect(grid.maxElevation == grid.values.max())
    }

    @Test("Garbage data throws elevationDecodingFailed")
    func garbageThrows() {
        let garbage = Data("not an image at all".utf8)
        #expect(throws: DioramaError.self) {
            _ = try TerrariumDecoder.decodeElevation(from: garbage)
        }
    }

    @Test("Both providers' decodeElevation forward to the same decoder")
    func providersAgree() throws {
        let png = TerrainRollerTests.terrariumPNG(elevation: 1234, size: 4)
        let a = try TerrainTileProvider.decodeElevation(from: png)
        let b = try MapTilerTerrainProvider.decodeElevation(from: png)
        #expect(a.values == b.values)
        #expect(a.width == b.width && a.height == b.height)
    }
}
