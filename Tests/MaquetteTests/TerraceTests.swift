import CoreGraphics
import Foundation
import SwiftUI
import Testing
import simd
@testable import Maquette

/// The terraced effect rebuilds the chunk's surface rather than drawing over it, so what it can get
/// wrong is the chunk itself.
///
/// Three things matter more than the rest, and none of them shows up in a vertex or triangle count.
/// A plateau that is not *exactly* flat shades as a gradient and the whole treatment collapses back
/// into low-resolution terrain. A ladder that drifts between steps re-cuts the model on every frame
/// of a drag. And a wall left un-terraced stands proud of the surface it is supposed to meet, which
/// is a ragged lip of strata all around the rim — visible immediately on screen and invisible to
/// anything that only counts buffers.
@Suite("Terrace Effect Tests")
struct TerraceTests {

    // MARK: - Fixtures

    /// A single-tile height field rising as a smooth ramp across the region.
    private func rampHeightField(resolution: Int = 32, extent: Float = 1.0) -> TerrainHeightField {
        var values: [Float] = []
        for row in 0..<resolution {
            for col in 0..<resolution {
                let u = Float(col) / Float(resolution - 1)
                let v = Float(row) / Float(resolution - 1)
                values.append(100 + u * 300 + v * 120)
            }
        }
        return TerrainHeightField(
            grids: [ElevationGrid(width: resolution, height: resolution, values: values)],
            tilePositions: [(x: 0, y: 0)],
            extent: SIMD2(extent, extent),
            elevationScale: 0.001
        )
    }

    private var square: DioramaBoundary {
        DioramaBoundary(vertices: [
            SIMD2(-0.4, -0.4), SIMD2(-0.4, 0.4), SIMD2(0.4, 0.4), SIMD2(0.4, -0.4),
        ])
    }

    private func chunk(
        resolution: Int = 40,
        baseDepth: Float = 0.2
    ) -> TerrainSolidGenerator.Geometry {
        TerrainSolidGenerator.buildGeometry(
            heightField: rampHeightField(),
            boundary: square,
            baseDepth: baseDepth,
            includesWalls: true,
            includesBottom: true,
            resolution: resolution
        )
    }

    /// A ladder over whatever relief a surface has.
    private func bands(of buffers: TerrainSolidGenerator.Buffers, count: Int = 12) -> TerraceBands {
        let relief = TerraceGeometry.relief(of: buffers.positions)!
        return TerraceBands(dividing: relief.lower, relief.upper, into: count)!
    }

    private func triangles(of mesh: IndexedMesh) -> [(Tiles3DVertex, Tiles3DVertex, Tiles3DVertex)] {
        var result: [(Tiles3DVertex, Tiles3DVertex, Tiles3DVertex)] = []
        var index = 0
        while index < mesh.indices.count {
            let a = mesh.vertices[Int(mesh.indices[index])]
            let b = mesh.vertices[Int(mesh.indices[index + 1])]
            let c = mesh.vertices[Int(mesh.indices[index + 2])]
            result.append((a, b, c))
            index += 3
        }
        return result
    }

    // MARK: - The ladder

    /// The whole treatment rests on this: a height is dropped to its rung and never lifted, so the
    /// terraced surface sits at or below the terrain it came from and never pokes through it.
    @Test("A rung sits on or below the height that chose it, within one step")
    func aRungNeverRises() {
        let ladder = TerraceBands(dividing: -2, 8, into: 20)!
        for step in 0...400 {
            let y = -3 + Float(step) * 0.03
            let level = ladder.level(ofRung: ladder.rung(of: y))
            #expect(level <= y + 1e-5)
            #expect(level > y - ladder.step - 1e-5)
        }
    }

    /// The steps have to be evenly spaced, or the model reads as terrain that has been rounded rather
    /// than as one cut from stacked sheets.
    @Test("Consecutive rungs are one step apart")
    func rungsAreEvenlySpaced() {
        let ladder = TerraceBands(dividing: 0, 5, into: 10)!
        for rung in -5...20 {
            let delta = ladder.level(ofRung: rung + 1) - ladder.level(ofRung: rung)
            #expect(abs(delta - ladder.step) < 1e-5)
        }
    }

    /// `.elevationMeters` is the contour-model reading: the steps land on multiples of a real
    /// elevation, not on multiples above whatever height the region happens to bottom out at.
    @Test("Elevation-spaced steps land on real elevation multiples")
    func elevationStepsLandOnRealMultiples() {
        let scale: Float = 0.002
        let baseline: Float = 1237
        let ladder = TerraceBands(
            everyMeters: 100,
            elevationScale: scale,
            baselineElevation: baseline,
            lower: 0,
            upper: 1.0
        )!

        for step in 0...50 {
            let y = Float(step) * 0.02
            let elevation = ladder.level(ofRung: ladder.rung(of: y)) / scale + baseline
            #expect(abs(elevation / 100 - (elevation / 100).rounded()) < 1e-3)
        }
    }

    /// Panning is unbounded, so ground far outside the relief measured at `apply` still has to be
    /// painted something. Running off the end of the palette is the one thing it must not do.
    @Test("Palette lookup clamps rather than running off either end")
    func paletteClampsOutsideTheMeasuredRelief() {
        let ladder = TerraceBands(dividing: 0, 4, into: 8)!
        #expect(ladder.paletteIndex(ofRung: ladder.rung(of: -50)) == 0)
        #expect(ladder.paletteIndex(ofRung: ladder.rung(of: 50)) == ladder.count - 1)
        for rung in -20...40 {
            let index = ladder.paletteIndex(ofRung: rung)
            #expect(index >= 0 && index < ladder.count)
        }
    }

    // MARK: - The surface

    /// The defining property. A plateau that is only *nearly* flat shades as a gradient, and the
    /// treatment falls back into looking like terrain rendered at too low a resolution.
    @Test("Every plateau triangle is exactly flat and faces exactly up")
    func plateausAreExactlyFlat() {
        let geometry = chunk()
        let ladder = bands(of: geometry.top)
        var mesh = IndexedMesh()
        TerraceGeometry.buildSurface(from: geometry.top, bands: ladder, into: &mesh)

        var plateaus = 0
        for (a, b, c) in triangles(of: mesh) where a.uv.y == TerraceGeometry.plateauRow {
            plateaus += 1
            #expect(a.position.y == b.position.y)
            #expect(b.position.y == c.position.y)
            #expect(a.normal == SIMD3<Float>(0, 1, 0))
            // A flat triangle whose corners disagreed about colour would band across its own face.
            #expect(a.uv == b.uv)
            #expect(b.uv == c.uv)
        }
        #expect(plateaus > 0)
    }

    /// The other half of the same property: a riser is a step face, so it must be steep, and it must
    /// be painted as one flat colour rather than fading into the plateau it joins.
    @Test("Every riser triangle is one flat colour on a near-vertical face")
    func risersAreSteepAndFlatlyPainted() {
        let geometry = chunk()
        let ladder = bands(of: geometry.top)
        var mesh = IndexedMesh()
        TerraceGeometry.buildSurface(from: geometry.top, bands: ladder, into: &mesh)

        var risers = 0
        for (a, b, c) in triangles(of: mesh) where a.uv.y == TerraceGeometry.riserRow {
            risers += 1
            #expect(a.uv == b.uv)
            #expect(b.uv == c.uv)
            #expect(abs(simd_length(a.normal) - 1) < 1e-4)
            #expect(a.normal == b.normal)
            // Rungs differ across a riser, so it cannot be horizontal.
            #expect(abs(a.normal.y) < 0.999)
        }
        #expect(risers > 0)
    }

    /// Every height in the output is a rung, everywhere, including inside the riser copies — the one
    /// place a stray interpolated height could hide.
    @Test("No vertex sits between rungs")
    func everyHeightIsARung() {
        let geometry = chunk()
        let ladder = bands(of: geometry.top)
        var mesh = IndexedMesh()
        TerraceGeometry.buildSurface(from: geometry.top, bands: ladder, into: &mesh)

        for vertex in mesh.vertices {
            let level = ladder.level(ofRung: ladder.rung(of: vertex.position.y))
            #expect(abs(level - vertex.position.y) < 1e-4)
        }
    }

    /// The chunk is clipped to its outline before the effect ever sees it, and the effect moves
    /// nothing horizontally — so the terraced copy inherits the cut edge exactly. If it did not, the
    /// steps would spill past the walls.
    @Test("Terracing moves nothing horizontally")
    func theOutlineIsInherited() {
        let geometry = chunk()
        let ladder = bands(of: geometry.top)
        var mesh = IndexedMesh()
        TerraceGeometry.buildSurface(from: geometry.top, bands: ladder, into: &mesh)

        var footprint: Set<SIMD2<Float>> = []
        for position in geometry.top.positions {
            footprint.insert(SIMD2(position.x, position.z))
        }
        for vertex in mesh.vertices {
            #expect(footprint.contains(SIMD2(vertex.position.x, vertex.position.z)))
        }

        let source = TerraceTests.bounds(of: geometry.top.positions)
        let built = TerraceTests.bounds(of: mesh.vertices.map(\.position))
        #expect(abs(source.min.x - built.min.x) < 1e-5)
        #expect(abs(source.max.x - built.max.x) < 1e-5)
        #expect(abs(source.min.z - built.min.z) < 1e-5)
        #expect(abs(source.max.z - built.max.z) < 1e-5)
    }

    /// Nothing is dropped and nothing is invented: every source triangle comes out as exactly one
    /// triangle, either a plateau or a riser.
    @Test("Triangle count survives terracing")
    func everyTriangleSurvives() {
        let geometry = chunk()
        let ladder = bands(of: geometry.top)
        var mesh = IndexedMesh()
        TerraceGeometry.buildSurface(from: geometry.top, bands: ladder, into: &mesh)

        #expect(mesh.indices.count == geometry.top.indices.count)
    }

    /// A pan changes heights and nothing else, so the ladder must not change with them: the same
    /// ladder over moved ground has to put its steps at the same heights, or the whole model jumps on
    /// every frame of a drag.
    @Test("A frozen ladder puts its steps at the same heights over new ground")
    func theLadderDoesNotMoveWhenTheGroundDoes() {
        let field = rampHeightField()
        var geometry = TerrainSolidGenerator.buildGeometry(
            heightField: field,
            boundary: square,
            baseDepth: 0.2,
            includesWalls: true,
            includesBottom: true,
            resolution: 40
        )
        let ladder = bands(of: geometry.top)

        var before = IndexedMesh()
        TerraceGeometry.buildSurface(from: geometry.top, bands: ladder, into: &before)
        let levelsBefore = Set(before.vertices.map { $0.position.y })

        TerrainSolidGenerator.resample(&geometry, heightField: field, panOffset: SIMD2(0.15, -0.1))
        var after = IndexedMesh()
        TerraceGeometry.buildSurface(from: geometry.top, bands: ladder, into: &after)
        let levelsAfter = Set(after.vertices.map { $0.position.y })

        // The ground moved, so which rungs are in use may differ — but every height in play still
        // has to be a rung of the same ladder, at the same absolute heights.
        #expect(levelsBefore != levelsAfter)
        for level in levelsAfter {
            #expect(abs(ladder.level(ofRung: ladder.rung(of: level)) - level) < 1e-4)
        }
    }

    // MARK: - The walls

    /// The failure this exists to catch is visible from any angle and invisible to a buffer count:
    /// quantization rounds heights down, so a wall left alone stands proud of the terraced surface it
    /// meets and shows a ragged lip of strata all the way around the rim.
    @Test("The wall's rim lands on the terraced surface, not on the terrain it came from")
    func theWallFollowsTheSteps() {
        let geometry = chunk()
        let ladder = bands(of: geometry.top)
        var mesh = IndexedMesh()
        TerraceGeometry.buildWalls(
            from: geometry.walls,
            bands: ladder,
            baseDepth: 0.2,
            wallHeight: geometry.resampling.wallHeight,
            into: &mesh
        )

        #expect(mesh.vertices.count == geometry.walls.positions.count)
        for index in mesh.vertices.indices {
            let built = mesh.vertices[index].position
            let source = geometry.walls.positions[index]
            // Horizontal position is untouched either way, which is what keeps the rim welded to the
            // surface's own border vertices.
            #expect(built.x == source.x)
            #expect(built.z == source.z)

            if index % 2 == 0 {
                let level = max(ladder.level(ofRung: ladder.rung(of: source.y)), -0.2)
                #expect(abs(built.y - level) < 1e-4)
                #expect(built.y <= source.y + 1e-5)
            } else {
                // Odd indices are the wall's lower rim and have no business moving.
                #expect(built.y == source.y)
            }
        }
    }

    /// The strata texture is normalized against the wall's own span, so a rim that moved without its
    /// texture coordinate moving would slide the bands.
    @Test("The wall's texture coordinates follow its rim")
    func theWallTextureFollowsTheRim() {
        let geometry = chunk()
        let ladder = bands(of: geometry.top)
        let baseDepth: Float = 0.2
        let height = geometry.resampling.wallHeight
        var mesh = IndexedMesh()
        TerraceGeometry.buildWalls(
            from: geometry.walls,
            bands: ladder,
            baseDepth: baseDepth,
            wallHeight: height,
            into: &mesh
        )

        for vertex in mesh.vertices {
            #expect(vertex.uv.y >= 0 && vertex.uv.y <= 1)
        }
        for index in stride(from: 0, to: mesh.vertices.count, by: 2) {
            let vertex = mesh.vertices[index]
            let expected = min(max((vertex.position.y + baseDepth) / height, 0), 1)
            #expect(abs(vertex.uv.y - expected) < 1e-4)
        }
    }

    /// The chunk must stay a solid. A wall whose rim was allowed below the bottom face would invert.
    @Test("The terraced wall stays inside the chunk's own depth")
    func theWallStaysAboveTheBottom() {
        let geometry = chunk(baseDepth: 0.05)
        // A ladder far coarser than the chunk's relief, so rounding down reaches for the floor.
        let ladder = TerraceBands(dividing: -1, 1, into: 2)!
        var mesh = IndexedMesh()
        TerraceGeometry.buildWalls(
            from: geometry.walls,
            bands: ladder,
            baseDepth: 0.05,
            wallHeight: geometry.resampling.wallHeight,
            into: &mesh
        )

        for vertex in mesh.vertices {
            #expect(vertex.position.y >= -0.05 - 1e-5)
        }
    }

    // MARK: - The palette

    /// Two rows standing in for two materials only works if a triangle's V lands squarely inside its
    /// own row, and the rows are the two halves of the strip.
    @Test("The palette's rows are where the geometry reads them")
    func theStripHasARowForEachKindOfFace() throws {
        let image = try #require(
            TerracePalette.makeImage(colors: [.red, .blue], count: 6, riserShade: 0.5)
        )
        #expect(image.width == 6 * 8)
        #expect(image.height == 4)
        #expect(TerraceGeometry.plateauRow < 0.5)
        #expect(TerraceGeometry.riserRow > 0.5)
    }

    /// The riser shade is what keeps a step legible on a face that happens to be lit as brightly as
    /// the plateau above it.
    @Test("Riser colours are darker than the tops they belong to")
    func risersArePaintedDarker() throws {
        let image = try #require(
            TerracePalette.makeImage(
                colors: [Color(white: 0.8)],
                count: 4,
                riserShade: 0.5
            )
        )
        let pixels = try #require(image.dataProvider?.data) as Data
        let bytesPerRow = image.bytesPerRow

        // Row 0 is the top of the image, which is the high-V half — the risers.
        let riser = pixels[0]
        let plateau = pixels[bytesPerRow * (image.height - 1)]
        #expect(riser < plateau)
        #expect(abs(Int(plateau) / 2 - Int(riser)) <= 1)
    }

    /// A band reads one column of the strip, so the columns have to be wide enough that the band's
    /// own sample point is nowhere near its neighbour's.
    @Test("A band's sample point sits inside its own column")
    func bandsSampleTheirOwnColumn() {
        let count = 7
        for band in 0..<count {
            let u = TerraceGeometry.paletteU(band, count: count)
            #expect(u > Float(band) / Float(count))
            #expect(u < Float(band + 1) / Float(count))
        }
    }

    /// The ramp is a description of the palette and the ladder is a description of the terrain; the
    /// two must not have to agree on a count.
    @Test("A short ramp stretches across however many bands there are")
    func theRampIsIndependentOfTheBandCount() {
        let ramp: [(Float, Float, Float)] = [(0, 0, 0), (1, 1, 1)]
        let first = TerracePalette.color(atBand: 0, of: 9, ramp: ramp)
        let last = TerracePalette.color(atBand: 8, of: 9, ramp: ramp)
        let middle = TerracePalette.color(atBand: 4, of: 9, ramp: ramp)

        #expect(abs(first.0 - 0) < 1e-5)
        #expect(abs(last.0 - 1) < 1e-5)
        #expect(abs(middle.0 - 0.5) < 1e-5)
    }

    // MARK: - Helpers

    private static func bounds(
        of positions: [SIMD3<Float>]
    ) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for position in positions {
            lo = simd_min(lo, position)
            hi = simd_max(hi, position)
        }
        return (lo, hi)
    }
}
