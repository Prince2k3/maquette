import Foundation
import Testing
import simd
@testable import Maquette

/// The strata wall is the same wall at every ground zoom — the same depth *and* the same height.
///
/// A pinch widens the *map*, not the object, so neither term of the band `baseDepth + rimY` may
/// follow it. Both halves of that were shipped wrong in turn and each is measured here:
///
/// - The earth mass used to scale with the zoom, to hold the chunk's total thickness constant. On
///   the Pan preset one pinch took the ground scale 1.023 → 1.954 and the earth mass 0.2045 m →
///   0.2961 m, putting the underside 112 px lower on screen.
/// - Pinning the base alone then left the band riding the terrain down as the relief compressed:
///   the same pinch took the rim at front centre 1421 → 1570 px and the ochre band 551 → 402.
///
/// So the zoom moves the *datum* instead, compressing the terrain about the rim rather than about
/// its own floor. Each test below drives the ladder the way ``DioramaStore/setGroundScale(_:)``
/// does — the elevation scale divided by the scale and the baseline from ``GroundDatum`` — because
/// dividing the scale alone is precisely the behaviour this replaces.
@Suite("Wall depth under ground zoom")
struct WallDepthTests {
    private let extent = SIMD2<Float>(1.0, 1.0)
    private var boundary: DioramaBoundary {
        DioramaBoundary.make(shape: .circular, extent: extent)
    }

    /// A cone, so the rim carries real relief rather than sitting flat.
    private func heightField(elevationScale: Float, baselineElevation: Float? = nil) -> TerrainHeightField {
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
            extent: extent,
            elevationScale: elevationScale,
            baselineElevation: baselineElevation
        )
    }

    /// The cone turned inside out, so the region's lowest ground sits *inside* the outline.
    private func basinField(elevationScale: Float, baselineElevation: Float? = nil) -> TerrainHeightField {
        let resolution = 32
        var values: [Float] = []
        for row in 0..<resolution {
            for col in 0..<resolution {
                let dx = Float(col) / Float(resolution - 1) - 0.5
                let dz = Float(row) / Float(resolution - 1) - 0.5
                values.append(400 - max(0, 1 - sqrt(dx * dx + dz * dz) * 1.2) * 300)
            }
        }
        return TerrainHeightField(
            grids: [ElevationGrid(width: resolution, height: resolution, values: values)],
            tilePositions: [(x: 0, y: 0)],
            extent: extent,
            elevationScale: elevationScale,
            baselineElevation: baselineElevation
        )
    }

    /// The height field the chunk would be re-read through at a given ground scale.
    private func zoomed(_ datum: GroundDatum, generatedScale: Float, to scale: Float) -> TerrainHeightField {
        heightField(
            elevationScale: generatedScale / scale,
            baselineElevation: datum.baseline(atGroundScale: scale)
        )
    }

    private func geometry(baseDepth: Float, elevationScale: Float) -> TerrainSolidGenerator.Geometry {
        TerrainSolidGenerator.buildGeometry(
            heightField: heightField(elevationScale: elevationScale),
            boundary: boundary,
            baseDepth: baseDepth,
            includesWalls: true,
            includesBottom: true,
            resolution: 64
        )
    }

    /// `appendWallQuad` emits top, bottom, top, bottom.
    ///
    /// The rim comes back as a mean because a mean is what the rule pins: the ring's waviness rides
    /// the elevation scale down like everything else, so the tallest single wall vertex legitimately
    /// comes closer to the mean as the map widens.
    private func rimAndBase(
        _ walls: TerrainSolidGenerator.Buffers
    ) -> (rim: Float, spread: Float, base: ClosedRange<Float>) {
        var rims: [Float] = []
        var lowest = Float.greatestFiniteMagnitude
        var highest = -Float.greatestFiniteMagnitude
        for (index, position) in walls.positions.enumerated() {
            if index.isMultiple(of: 2) {
                rims.append(position.y)
            } else {
                lowest = min(lowest, position.y)
                highest = max(highest, position.y)
            }
        }
        let mean = rims.reduce(0, +) / Float(rims.count)
        let spread = (rims.max() ?? 0) - (rims.min() ?? 0)
        return (mean, spread, lowest...highest)
    }

    @Test("The band keeps its height however far the map is widened")
    func theBandHoldsAcrossTheZoom() {
        let generatedDepth: Float = 0.2
        let generatedElevationScale: Float = 0.001
        let datum = GroundDatum.measured(
            boundary: boundary,
            heightField: heightField(elevationScale: generatedElevationScale)
        )
        var chunk = geometry(baseDepth: generatedDepth, elevationScale: generatedElevationScale)
        let before = rimAndBase(chunk.walls)
        #expect(before.base == -generatedDepth ... -generatedDepth)
        // The wall stands on the outline, where the cone has already fallen away from its peak — so
        // this is a fraction of the chunk's relief, not all of it. It has to be well clear of zero
        // or a rim that failed to hold would be indistinguishable from one that did.
        #expect(before.rim > 0.05, "The fixture has to carry relief or this measures nothing")

        // The ladder a pinch actually walks. The tolerance is against the generated band rather
        // than an absolute, since what is asserted is that the band did not move by anything a
        // viewer could see — the old rule put it at `before.rim / scale`, which by scale 8 is an
        // eighth of it.
        for scale in [Float(1.5), 2, 8, 64, 256] {
            TerrainSolidGenerator.resample(
                &chunk,
                heightField: zoomed(datum, generatedScale: generatedElevationScale, to: scale),
                panOffset: .zero
            )
            let after = rimAndBase(chunk.walls)
            #expect(after.base == -generatedDepth ... -generatedDepth,
                    "At scale \(scale) the wall's base has moved to \(after.base)")
            #expect(abs(after.rim - before.rim) < before.rim * 0.02,
                    "At scale \(scale) the mean rim moved \(before.rim) → \(after.rim)")
            // And the profile is what pays for it: the ring flattens even as its mean holds.
            #expect(after.spread < before.spread / (scale * 0.98),
                    "At scale \(scale) the rim's waviness should have compressed with the relief")
        }
    }

    /// The other direction, which is where a scaled earth mass used to run out of room: a zoom *in*
    /// magnifies the relief, and a rule that gave the earth mass away to pay for it would eventually
    /// have turned the solid inside out. Holding the base fixed has no such end.
    @Test("Zooming in cannot turn the solid inside out")
    func theBaseHoldsOnTheWayIn() {
        let generatedDepth: Float = 0.2
        let generated: Float = 0.001
        let datum = GroundDatum.measured(
            boundary: boundary, heightField: heightField(elevationScale: generated)
        )
        var chunk = geometry(baseDepth: generatedDepth, elevationScale: generated)

        for scale in [Float(0.5), 0.25, 0.05] {
            TerrainSolidGenerator.resample(
                &chunk,
                heightField: zoomed(datum, generatedScale: generated, to: scale),
                panOffset: .zero
            )
            let after = rimAndBase(chunk.walls)
            #expect(after.base == -generatedDepth ... -generatedDepth)
            #expect(after.rim > -generatedDepth, "The rim must stay above the floor it stands on")
        }
    }

    /// Zooming in sinks the low ground below Y = 0 and eventually below the base, which is the trade
    /// the rim datum makes. It may not take the solid with it: the surface rests on the floor.
    ///
    /// A basin rather than the cone, because the cone's lowest ground is in the corners the circular
    /// outline cuts away — so nothing inside the chunk ever reads below the rim by enough to reach
    /// the floor, and the assertion would pass without exercising anything.
    @Test("Ground the zoom pushes below the floor rests on it")
    func theSurfaceRestsOnTheFloorWhenZoomedIn() {
        let generatedDepth: Float = 0.2
        let generated: Float = 0.001
        let datum = GroundDatum.measured(
            boundary: boundary, heightField: basinField(elevationScale: generated)
        )
        var chunk = TerrainSolidGenerator.buildGeometry(
            heightField: basinField(elevationScale: generated),
            boundary: boundary,
            baseDepth: generatedDepth,
            includesWalls: true,
            includesBottom: true,
            resolution: 64
        )
        TerrainSolidGenerator.resample(
            &chunk,
            heightField: basinField(
                elevationScale: generated / 0.05,
                baselineElevation: datum.baseline(atGroundScale: 0.05)
            ),
            panOffset: .zero
        )
        #expect(chunk.top.positions.allSatisfy { $0.y >= -generatedDepth - 1e-5 })
        #expect(chunk.top.positions.contains { $0.y < 0 },
                "A hard zoom in has to actually push ground below Y = 0 or this asserts nothing")
        #expect(chunk.top.positions.contains { abs($0.y + generatedDepth) < 1e-5 },
                "…and far enough below to reach the floor, or the clamp is untested")
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
