import Foundation
import Testing
import simd
@testable import Maquette

/// The strata wall is the same wall at every ground zoom.
///
/// A pinch widens the *map*, not the object, and the earth mass is what the wall is made of — so
/// scaling it with the zoom answers a gesture about the ground by resizing the chunk. Measured on
/// the Pan preset before this: one pinch took the ground scale 1.023 → 1.954 and the earth mass
/// 0.2045 m → 0.2961 m, putting the chunk's underside 112 px lower on screen.
///
/// The wall's silhouette is `rim + baseDepth`, and only the first of those two may move: the rim
/// rides the elevation scale down because that is the map pulling back, while the base stays where
/// generation put it.
@Suite("Wall depth under ground zoom")
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

    @Test("The earth mass is untouched however far the map is widened")
    func theBaseHoldsAcrossTheZoom() {
        let generatedDepth: Float = 0.2
        let generatedElevationScale: Float = 0.001
        var chunk = geometry(baseDepth: generatedDepth, elevationScale: generatedElevationScale)
        let before = rimAndBase(chunk.walls)
        #expect(before.base == -generatedDepth ... -generatedDepth)
        // The wall stands on the outline, where the cone has already fallen away from its peak — so
        // this is a third of the chunk's relief, not all of it. It has to be well clear of zero or
        // a rim that failed to compress would be indistinguishable from one that did.
        #expect(before.rim > 0.05, "The fixture has to carry relief or this measures nothing")

        // The ladder a pinch actually walks: each step divides the elevation scale, and nothing about
        // the chunk's own geometry is allowed to follow.
        for scale in [Float(1.5), 2, 8, 64, 256] {
            TerrainSolidGenerator.resample(
                &chunk,
                heightField: heightField(elevationScale: generatedElevationScale / scale),
                panOffset: .zero
            )
            let after = rimAndBase(chunk.walls)
            #expect(after.base == -generatedDepth ... -generatedDepth,
                    "At scale \(scale) the wall's base has moved to \(after.base)")
            #expect(abs(after.rim - before.rim / scale) < 1e-4,
                    "At scale \(scale) the rim should be \(before.rim / scale), not \(after.rim)")
        }
    }

    /// The other direction, which is where a scaled earth mass used to run out of room: a zoom *in*
    /// magnifies the relief, and a rule that gave the earth mass away to pay for it would eventually
    /// have turned the solid inside out. Holding the base fixed has no such end.
    @Test("Zooming in cannot turn the solid inside out")
    func theBaseHoldsOnTheWayIn() {
        let generatedDepth: Float = 0.2
        var chunk = geometry(baseDepth: generatedDepth, elevationScale: 0.001)

        for scale in [Float(0.5), 0.25, 0.05] {
            TerrainSolidGenerator.resample(
                &chunk, heightField: heightField(elevationScale: 0.001 / scale), panOffset: .zero
            )
            let after = rimAndBase(chunk.walls)
            #expect(after.base == -generatedDepth ... -generatedDepth)
            #expect(after.rim > -generatedDepth, "The rim must stay above the floor it stands on")
        }
    }

    /// The pan case, which is the same case: same base, different ground.
    @Test("Sliding the ground beneath the chunk leaves the underside alone")
    func aPanDoesNotMoveTheBase() {
        var chunk = geometry(baseDepth: 0.2, elevationScale: 0.001)
        TerrainSolidGenerator.resample(
            &chunk, heightField: heightField(elevationScale: 0.001), panOffset: SIMD2(0.2, -0.15)
        )
        #expect(rimAndBase(chunk.walls).base == -0.2 ... -0.2)
    }

    /// Panning far enough finds ground below the frozen baseline, and the wall may not invert or
    /// poke through the bottom face when it does.
    @Test("Terrain below the chunk's own floor rests on it")
    func theSurfaceCannotFallThroughTheBase() {
        var chunk = geometry(baseDepth: 0.02, elevationScale: 0.001)
        // A cone falling away from its peak, sampled well outside the fixture, clamps to the border
        // — so shrink the base instead until the floor is the binding constraint.
        chunk.resampling.baseDepth = 0.0001
        TerrainSolidGenerator.resample(
            &chunk, heightField: heightField(elevationScale: 0.001), panOffset: .zero
        )
        #expect(chunk.top.positions.allSatisfy { $0.y >= -0.0001 })
    }
}
