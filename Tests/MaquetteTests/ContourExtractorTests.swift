import Foundation
import Testing
import simd
@testable import Maquette

/// `ContourExtractor` traces the hologram's lines straight from the chunk's own triangles, which is
/// what makes a contour stop exactly on the cut edge without repeating the boundary clip. Two things
/// about it fail silently and are what these check.
///
/// A **hole** in a line is invisible in a segment count and obvious on screen, so the tests measure
/// the *total length* a level traces rather than how many pieces it came in. The index window a
/// triangle scans is deliberately widened by one at each end for the same reason the boundary grid is
/// padded: a wasted iteration costs an arithmetic test, a missed one deletes part of a line.
///
/// A **doubled** line is equally invisible in a count and shows on screen as a contour twice as
/// bright as its neighbours. It happens where a level lands exactly on a shared grid vertex and both
/// triangles claim it, which is why the extractor treats "on the level" as above it, consistently.
@Suite("Contour Extractor Tests")
struct ContourExtractorTests {

    // MARK: - Meshes

    /// A grid over the unit square in XZ, with each vertex's height given by `height`.
    ///
    /// `keep` decides which cells are present, which is how the boundary-conformance test builds a
    /// surface with ground missing from it the way a clipped chunk has.
    static func grid(
        divisions: Int,
        height: (Float, Float) -> Float,
        keep: (Float, Float) -> Bool = { _, _ in true }
    ) -> (positions: [SIMD3<Float>], indices: [UInt32]) {
        let step = 1 / Float(divisions)
        var positions: [SIMD3<Float>] = []
        for j in 0...divisions {
            for i in 0...divisions {
                let x = Float(i) * step
                let z = Float(j) * step
                positions.append(SIMD3(x, height(x, z), z))
            }
        }

        let row = divisions + 1
        var indices: [UInt32] = []
        for j in 0..<divisions {
            for i in 0..<divisions {
                let cx = (Float(i) + 0.5) * step
                let cz = (Float(j) + 0.5) * step
                guard keep(cx, cz) else { continue }
                let v00 = UInt32(j * row + i)
                let v10 = v00 + 1
                let v01 = UInt32((j + 1) * row + i)
                let v11 = v01 + 1
                indices.append(contentsOf: [v00, v01, v11, v00, v11, v10])
            }
        }
        return (positions, indices)
    }

    static func totalLength(_ segments: [ContourExtractor.Segment]) -> Float {
        segments.reduce(0) { $0 + simd_length($1.b - $1.a) }
    }

    // MARK: - Level arithmetic

    @Test("Dividing a range places levels inside it, never on its ends")
    func dividingExcludesTheEnds() {
        let levels = ContourExtractor.LevelSet.dividing(0, 10, into: 4)
        #expect(levels.count == 4)
        #expect(abs(levels.step - 2) < 1e-5)
        #expect(abs(levels.level(0) - 2) < 1e-5)
        #expect(abs(levels.level(3) - 8) < 1e-5)
        // A level sitting on the range's own end would trace the single lowest or highest point of
        // the terrain, which draws nothing but costs a full pass to discover.
        #expect(levels.level(0) > 0)
        #expect(levels.level(levels.count - 1) < 10)
    }

    @Test("A degenerate range asks for no levels rather than dividing by zero")
    func dividingDegenerateRanges() {
        #expect(ContourExtractor.LevelSet.dividing(5, 5, into: 4).count == 0)
        #expect(ContourExtractor.LevelSet.dividing(10, 0, into: 4).count == 0)
        #expect(ContourExtractor.LevelSet.dividing(0, 10, into: 0).count == 0)
        #expect(ContourExtractor.LevelSet.dividing(0, 10, into: -3).count == 0)
    }

    /// Fixed spacing aligns to multiples of the spacing, not to the terrain's own floor.
    ///
    /// That is what keeps a contour standing still while the ground pans beneath it: aligning to the
    /// range's lower end would re-place every line the moment the lowest visible point changed, and
    /// the whole set would crawl during a drag.
    @Test("Fixed spacing aligns to multiples of the spacing")
    func spacedAlignsToMultiples() {
        let levels = ContourExtractor.LevelSet.spaced(10, from: 5, to: 45)
        #expect(levels.count == 4)
        #expect(abs(levels.level(0) - 10) < 1e-4)
        #expect(abs(levels.level(3) - 40) < 1e-4)

        // Crossing zero must not shift the alignment.
        let straddling = ContourExtractor.LevelSet.spaced(10, from: -5, to: 15)
        #expect(straddling.count == 2)
        #expect(abs(straddling.level(0)) < 1e-4)
        #expect(abs(straddling.level(1) - 10) < 1e-4)
    }

    @Test("Spacing wider than the relief asks for no levels")
    func spacedWiderThanRelief() {
        #expect(ContourExtractor.LevelSet.spaced(100, from: 5, to: 45).count == 0)
        #expect(ContourExtractor.LevelSet.spaced(0, from: 0, to: 10).count == 0)
        #expect(ContourExtractor.LevelSet.spaced(-5, from: 0, to: 10).count == 0)
    }

    // MARK: - Extraction

    /// The test that catches holes. A ramp `y = x` over the unit square has an isoline at every
    /// level that runs the full depth of the square, so each level must trace exactly 1.0 of length —
    /// a missed triangle shortens it and nothing else about the output changes.
    @Test("Every level of a ramp traces its full length")
    func rampLevelsAreComplete() {
        let mesh = Self.grid(divisions: 16, height: { x, _ in x })
        let levels = ContourExtractor.LevelSet.dividing(0, 1, into: 7)
        let segments = ContourExtractor.isolines(
            positions: mesh.positions, indices: mesh.indices, axis: .y, levels: levels
        )
        #expect(!segments.isEmpty)

        for index in 0..<levels.count {
            let level = levels.level(index)
            let atLevel = segments.filter { abs($0.a.y - level) < 1e-4 && abs($0.b.y - level) < 1e-4 }
            #expect(abs(Self.totalLength(atLevel) - 1) < 1e-3,
                    "level \(level) traced \(Self.totalLength(atLevel))")
            // On this ramp height is x, so a contour is a line of constant x.
            for segment in atLevel {
                #expect(abs(segment.a.x - level) < 1e-4)
                #expect(abs(segment.b.x - level) < 1e-4)
            }
        }
    }

    /// The window a triangle scans is index arithmetic, and arithmetic on floats lands differently
    /// depending on where the levels fall relative to the grid. Sweeping the offset is what would
    /// catch a window that is one short at either end.
    @Test("No level is missed wherever it falls between grid lines")
    func levelsOffGridAreStillComplete() {
        let mesh = Self.grid(divisions: 12, height: { x, _ in x })
        for offset in stride(from: Float(0), through: 0.09, by: 0.01) {
            let levels = ContourExtractor.LevelSet(first: 0.05 + offset, step: 0.1, count: 9)
            let segments = ContourExtractor.isolines(
                positions: mesh.positions, indices: mesh.indices, axis: .y, levels: levels
            )
            let expected = Float(levels.count)
            #expect(abs(Self.totalLength(segments) - expected) < 2e-3,
                    "offset \(offset) traced \(Self.totalLength(segments)) of \(expected)")
        }
    }

    /// A level landing exactly on a shared grid line is claimed by one triangle, not both.
    ///
    /// Doubled geometry is invisible in a length total only if you measure it per level, which is why
    /// this one checks the total against the count of levels rather than eyeballing the segments.
    @Test("A level lying exactly on a grid line is traced once, not twice")
    func levelsOnGridLinesAreNotDoubled() {
        let mesh = Self.grid(divisions: 4, height: { x, _ in x })
        let levels = ContourExtractor.LevelSet(first: 0.25, step: 0.25, count: 3)
        let segments = ContourExtractor.isolines(
            positions: mesh.positions, indices: mesh.indices, axis: .y, levels: levels
        )
        #expect(abs(Self.totalLength(segments) - 3) < 1e-3,
                "traced \(Self.totalLength(segments)), expected 3")
    }

    @Test("Levels outside the relief trace nothing")
    func levelsOutsideTheReliefDrawNothing() {
        let mesh = Self.grid(divisions: 8, height: { x, _ in x })
        let above = ContourExtractor.LevelSet(first: 2, step: 0.5, count: 4)
        let below = ContourExtractor.LevelSet(first: -4, step: 0.5, count: 4)
        #expect(ContourExtractor.isolines(
            positions: mesh.positions, indices: mesh.indices, axis: .y, levels: above).isEmpty)
        #expect(ContourExtractor.isolines(
            positions: mesh.positions, indices: mesh.indices, axis: .y, levels: below).isEmpty)
    }

    /// The graticule is the same operation against a horizontal axis, and it has to come out draped
    /// over the relief rather than flattened — every vertex keeps the height it was extracted at.
    @Test("Isolines of a horizontal axis drape over the terrain")
    func horizontalAxisIsolinesFollowTheSurface() {
        // A ridge running along Z, so a line of constant X sits at one height and a line of constant
        // Z climbs over the ridge.
        let mesh = Self.grid(divisions: 16, height: { x, _ in 1 - abs(x - 0.5) * 2 })

        let alongZ = ContourExtractor.isolines(
            positions: mesh.positions, indices: mesh.indices,
            axis: .x, levels: ContourExtractor.LevelSet(first: 0.25, step: 0.25, count: 3)
        )
        #expect(!alongZ.isEmpty)
        for segment in alongZ {
            // Constant X, and flat because the ridge does not change along Z.
            #expect(abs(segment.a.x - segment.b.x) < 1e-4)
            #expect(abs(segment.a.y - segment.b.y) < 1e-4)
        }

        let alongX = ContourExtractor.isolines(
            positions: mesh.positions, indices: mesh.indices,
            axis: .z, levels: ContourExtractor.LevelSet(first: 0.5, step: 1, count: 1)
        )
        #expect(!alongX.isEmpty)
        // Horizontally it spans the square. Measuring its 3D length instead would come out longer,
        // and that surplus is exactly the climb the next assertion is looking for.
        let horizontal = alongX.reduce(Float(0)) { $0 + abs($1.b.x - $1.a.x) }
        #expect(abs(horizontal - 1) < 1e-3)
        // Draped: the line crosses the ridge, so it cannot be at one height.
        let heights = alongX.flatMap { [$0.a.y, $0.b.y] }
        let relief = (heights.max() ?? 0) - (heights.min() ?? 0)
        #expect(relief > 0.9, "graticule line flattened; relief \(relief)")
    }

    /// The whole reason for tracing the chunk's own triangles: where the surface was clipped away,
    /// there is nothing to trace, so the lines stop on the cut edge for free.
    @Test("Lines stop where the surface does")
    func linesInheritTheSurfaceClip() {
        // Keep only the half below the diagonal, the way a boundary clip leaves ground missing.
        let mesh = Self.grid(divisions: 16, height: { x, _ in x }, keep: { x, z in x + z < 1 })
        let segments = ContourExtractor.isolines(
            positions: mesh.positions, indices: mesh.indices,
            axis: .y, levels: ContourExtractor.LevelSet.dividing(0, 1, into: 7)
        )
        #expect(!segments.isEmpty)

        // A whole grid row of tolerance: the cells are kept or dropped whole, so the true edge is
        // stepped and a segment may reach the far corner of the last kept cell.
        let tolerance = Float(1) / 16 + 1e-4
        for segment in segments {
            #expect(segment.a.x + segment.a.z < 1 + tolerance)
            #expect(segment.b.x + segment.b.z < 1 + tolerance)
        }
    }

    @Test("A mesh with no triangles traces nothing")
    func emptyInputsTraceNothing() {
        let levels = ContourExtractor.LevelSet(first: 0.5, step: 0.5, count: 2)
        #expect(ContourExtractor.isolines(
            positions: [], indices: [], axis: .y, levels: levels).isEmpty)

        let mesh = Self.grid(divisions: 4, height: { x, _ in x })
        #expect(ContourExtractor.isolines(
            positions: mesh.positions, indices: mesh.indices, axis: .y,
            levels: ContourExtractor.LevelSet(first: 0, step: 0, count: 3)).isEmpty)
    }

    /// A perfectly flat surface has no contours at all. Worth pinning because the crossing test's
    /// "on the level counts as above it" convention is exactly what decides this, and the opposite
    /// convention would carpet a flat chunk in coincident lines.
    @Test("Flat ground draws no contours")
    func flatGroundHasNoContours() {
        let mesh = Self.grid(divisions: 8, height: { _, _ in 0.5 })
        let segments = ContourExtractor.isolines(
            positions: mesh.positions, indices: mesh.indices,
            axis: .y, levels: ContourExtractor.LevelSet(first: 0.5, step: 0.25, count: 3)
        )
        #expect(segments.isEmpty)
    }

    /// A horizontal axis is traced by the same code as the vertical one, and the hologram's graticule
    /// is its only caller — so a regression there would show up nowhere else. The height function is
    /// linear so the triangulated surface *is* the function, which lets the ruling be checked against
    /// it exactly: a graticule line has to lie on the ground, not float above it or sink into it.
    @Test("A horizontal trace lies on the surface at the levels it was asked for")
    func horizontalTraceLiesOnTheSurface() {
        let levels = ContourExtractor.LevelSet.dividing(0, 1, into: 6)
        let mesh = Self.grid(divisions: 10, height: { x, z in x * 0.3 - z * 0.7 })
        let segments = ContourExtractor.isolines(
            positions: mesh.positions, indices: mesh.indices, axis: .z, levels: levels
        )

        #expect(!segments.isEmpty)
        for segment in segments {
            for end in [segment.a, segment.b] {
                #expect(abs(end.y - (end.x * 0.3 - end.z * 0.7)) < 1e-4)
                let nearest = (0..<levels.count).map { abs(end.z - levels.level($0)) }.min() ?? 1
                #expect(nearest < 1e-4)
            }
        }
    }
}
