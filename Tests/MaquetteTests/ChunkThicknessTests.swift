import Foundation
import Testing
import simd
@testable import Maquette

/// The chunk is the same object at every ground zoom.
///
/// A pinch widens the *map*, not the object — but widening the map divides the elevation scale, and
/// the terrain is half of what the chunk's silhouette is made of. Left alone, the earth mass stays
/// put while the terrain above it flattens, so the block visibly thins out as the map pulls back and
/// thickens again on the way in. Measured on the Pan preset before this: one pinch took the ground
/// scale 1 → 2.095 and the strata band went 415 px → 305 px with the footprint unchanged.
@Suite("Chunk thickness under ground zoom")
struct ChunkThicknessTests {
    /// A generated chunk: 0.2 m of earth mass under 0.3 m of relief.
    private let generated: Float = 0.2
    private let relief: Float = 0.3

    private func depth(at scale: Float) -> Float {
        TerrainSolidGenerator.baseDepth(atGroundScale: scale, generated: generated, relief: relief)
    }

    /// The invariant itself: what the terrain gives up, the earth mass takes back.
    @Test("The chunk keeps its thickness as the map widens")
    func thicknessHoldsAcrossTheZoom() {
        let thickness = generated + relief
        for step in 0...80 {
            let scale = Float(exp2(Double(step) / 10))
            // The terrain's own share rides the elevation scale down; the earth mass makes it up.
            let drawn = depth(at: scale) + relief / scale
            #expect(abs(drawn - thickness) < 1e-5,
                    "At scale \(scale) the chunk is \(drawn) m thick, not \(thickness)")
        }
    }

    /// What it used to do, stated as the number the fix has to beat.
    @Test("An earth mass that stayed put would thin the chunk by a quarter")
    func theUncompensatedChunkThins() {
        let thickness = generated + relief
        let uncompensated = generated + relief / 2.095
        #expect(uncompensated / thickness < 0.8)
    }

    @Test("At the scale it was generated at, nothing moves")
    func theGeneratedScaleIsUntouched() {
        #expect(depth(at: 1) == generated)
    }

    /// The earth mass is bounded above by the thickness itself: at the far end the terrain has
    /// flattened to nothing and the block is all strata.
    @Test("The earth mass grows to the whole chunk and no further")
    func theDepthIsBoundedByTheThickness() {
        for scale in [Float(16), 256, 1_048_576] {
            #expect(depth(at: scale) < generated + relief)
        }
        #expect(depth(at: 1_048_576) > generated + relief - 1e-4)
    }

    /// A zoom *in* magnifies the relief instead, and past a point there is no earth mass left to
    /// give up — so the rule stops rather than inverting the solid.
    @Test("Zooming in stops before the chunk turns inside out")
    func theDepthFloorsOnTheWayIn() {
        for scale in [Float(0.5), 0.25, 0.05] {
            #expect(depth(at: scale) > 0)
        }
        #expect(depth(at: 0.25) == generated * TerrainSolidGenerator.minimumEarthMassShare)
        // Unfloored, a quarter-scale zoom would put the underside a full 0.7 m *above* Y = 0.
        #expect(generated + relief * (1 - 1 / Float(0.25)) < 0)
    }

    /// It reads the scale and nothing else. Deriving the depth from the terrain currently under the
    /// rim would move the chunk's underside on every pan step — the bobbing the frozen elevation
    /// baseline exists to prevent.
    @Test("A scale of zero is refused rather than divided by")
    func aDegenerateScaleKeepsTheGeneratedDepth() {
        #expect(depth(at: 0) == generated)
        #expect(depth(at: -1) == generated)
    }
}

/// And the same invariant on the geometry the wall is actually built from.
///
/// The wall's silhouette is `rim + baseDepth`, so both halves have to move: `resample` used to
/// leave the odd (base) vertices exactly where generation put them, which is right for a pan and
/// wrong for a zoom.
@Suite("Wall geometry under ground zoom")
struct WallDepthTests {
    /// A cone, so the rim carries real relief rather than sitting flat.
    private func heightField(elevationScale: Float) -> TerrainHeightField {
        let resolution = 32
        var values: [Float] = []
        for row in 0..<resolution {
            for col in 0..<resolution {
                let dx = Float(col) / Float(resolution - 1) - 0.5
                let dz = Float(row) / Float(resolution - 1) - 0.5
                values.append(100 + max(0, 1 - sqrt(dx * dx + dz * dz) * 1.2) * 300)
            }
        }
        return TerrainHeightField(
            grids: [ElevationGrid(width: resolution, height: resolution, values: values)],
            tilePositions: [(x: 0, y: 0)],
            extent: SIMD2(1.0, 1.0),
            elevationScale: elevationScale
        )
    }

    private func geometry(baseDepth: Float, elevationScale: Float) -> TerrainSolidGenerator.Geometry {
        TerrainSolidGenerator.buildGeometry(
            heightField: heightField(elevationScale: elevationScale),
            boundary: DioramaBoundary.make(shape: .circular, extent: SIMD2(1.0, 1.0)),
            baseDepth: baseDepth,
            includesWalls: true,
            includesBottom: true,
            resolution: 64
        )
    }

    /// `appendWallQuad` emits top, bottom, top, bottom.
    private func rimAndBase(
        _ walls: TerrainSolidGenerator.Buffers
    ) -> (rim: Float, base: ClosedRange<Float>) {
        var rim = -Float.greatestFiniteMagnitude
        var lowest = Float.greatestFiniteMagnitude
        var highest = -Float.greatestFiniteMagnitude
        for (index, position) in walls.positions.enumerated() {
            if index.isMultiple(of: 2) {
                rim = max(rim, position.y)
            } else {
                lowest = min(lowest, position.y)
                highest = max(highest, position.y)
            }
        }
        return (rim, lowest...highest)
    }

    @Test("Halving the elevation scale keeps the wall the height it was built at")
    func theWallKeepsItsHeight() {
        let generatedDepth: Float = 0.2
        var chunk = geometry(baseDepth: generatedDepth, elevationScale: 0.001)
        let before = rimAndBase(chunk.walls)
        #expect(before.base == -generatedDepth ... -generatedDepth)

        // `wallHeight` samples the boundary's own vertices and edge midpoints, while the wall quads
        // stand on wherever the clip cut each cell — so the two agree to within a sample, not
        // exactly. Either would do as the relief; what matters is that one of them is used.
        let generatedRelief = chunk.resampling.wallHeight - generatedDepth
        #expect(abs(generatedRelief - before.rim) < 1e-4)

        // What a ground scale of 2 does: the map widens, so a metre of relief is worth half as many
        // diorama metres, and the earth mass takes back exactly the difference.
        let scale: Float = 2
        let depth = TerrainSolidGenerator.baseDepth(
            atGroundScale: scale, generated: generatedDepth, relief: generatedRelief
        )
        chunk.resampling.baseDepth = depth
        TerrainSolidGenerator.resample(
            &chunk, heightField: heightField(elevationScale: 0.001 / scale), panOffset: .zero
        )

        let after = rimAndBase(chunk.walls)
        #expect(after.base == -depth ... -depth, "The wall's base has to follow the earth mass down")
        #expect(abs(after.rim - before.rim / scale) < 1e-4, "The rim is half the height it was")
        #expect(abs((after.rim + depth) - (before.rim + generatedDepth)) < 1e-4,
                "…so the wall the user sees is exactly as tall as it was")
    }

    /// The pan case, which is the one that must not change: same scale, different ground.
    @Test("Sliding the ground beneath the chunk leaves the underside alone")
    func aPanDoesNotMoveTheBase() {
        var chunk = geometry(baseDepth: 0.2, elevationScale: 0.001)
        TerrainSolidGenerator.resample(
            &chunk, heightField: heightField(elevationScale: 0.001), panOffset: SIMD2(0.2, -0.15)
        )
        #expect(rimAndBase(chunk.walls).base == -0.2 ... -0.2)
    }
}
