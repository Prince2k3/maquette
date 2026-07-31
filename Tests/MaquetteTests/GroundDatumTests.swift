import Foundation
import Testing
import simd
@testable import Maquette

/// What Y = 0 means as the ground is zoomed.
@Suite("The ground datum")
struct GroundDatumTests {
    private let extent = SIMD2<Float>(1.0, 1.0)

    /// A ramp running west to east, so a point's elevation is a readable function of x.
    private func rampField(baselineElevation: Float? = nil) -> TerrainHeightField {
        let resolution = 32
        var values: [Float] = []
        for _ in 0..<resolution {
            for col in 0..<resolution {
                values.append(100 + Float(col) / Float(resolution - 1) * 300)
            }
        }
        return TerrainHeightField(
            grids: [ElevationGrid(width: resolution, height: resolution, values: values)],
            tilePositions: [(x: 0, y: 0)],
            extent: extent,
            elevationScale: 0.001,
            baselineElevation: baselineElevation
        )
    }

    @Test("At the scale the chunk was generated at, nothing moves")
    func identityAtGeneration() {
        let datum = GroundDatum(generated: 100, rim: 250)
        #expect(datum.baseline(atGroundScale: 1) == 100)
    }

    /// The whole reason the type exists: `rimY` is what the eye reads off the silhouette, and it has
    /// to survive the elevation scale dividing by the zoom.
    @Test("The rim sits at the same diorama height at every ground scale")
    func theRimIsPinned() {
        let datum = GroundDatum(generated: 100, rim: 250)
        let generatedScale: Float = 0.001
        let expected = datum.rimHeight(generatedElevationScale: generatedScale)
        #expect(expected == (datum.rim - datum.generated) * generatedScale)

        for scale in [Float(0.05), 0.25, 1, 1.5, 2, 8, 64, 256] {
            let rimY = (datum.rim - datum.baseline(atGroundScale: scale)) * (generatedScale / scale)
            #expect(abs(rimY - expected) < 1e-6,
                    "At scale \(scale) the rim landed at \(rimY), not \(expected)")
        }
    }

    /// The trade, stated as a test rather than only as a claim: Y = 0 stops being the lowest ground
    /// the moment the map moves. Zoomed out the terrain floats above it; zoomed in it sinks below.
    @Test("Y = 0 is the floor only at the generated scale")
    func theFloorMovesWithTheZoom() {
        let datum = GroundDatum(generated: 100, rim: 250)
        // The lowest ground reads *below* the datum once the map is widened, so it renders above
        // Y = 0 — by `rimY₀·(s−1)/s`, which is what the doc claims.
        let generatedScale: Float = 0.001
        let rimY = (datum.rim - datum.generated) * generatedScale
        for scale in [Float(2), 8, 64] {
            let floorY = (datum.generated - datum.baseline(atGroundScale: scale)) * (generatedScale / scale)
            #expect(floorY > 0)
            #expect(abs(floorY - rimY * (scale - 1) / scale) < 1e-6)
        }
        // And the other way, which is where `resample`'s clamp earns its keep.
        for scale in [Float(0.5), 0.25, 0.05] {
            let floorY = (datum.generated - datum.baseline(atGroundScale: scale)) * (generatedScale / scale)
            #expect(floorY < 0)
        }
    }

    /// A scale of zero would divide the elevation scale by nothing, so the datum refuses to take
    /// part rather than returning an infinity for the height field to place terrain against.
    @Test("A degenerate scale falls back to the generated datum")
    func degenerateScale() {
        let datum = GroundDatum(generated: 100, rim: 250)
        #expect(datum.baseline(atGroundScale: 0) == 100)
        #expect(datum.baseline(atGroundScale: -1) == 100)
    }

    @Test("The generated datum is the height field's own baseline")
    func measuresTheGeneratedBaseline() {
        let field = rampField()
        let datum = GroundDatum.measured(
            boundary: DioramaBoundary.make(shape: .circular, extent: extent),
            heightField: field
        )
        #expect(datum.generated == field.baselineElevation)
    }

    /// On a ramp, a circle's rim averages the ramp's middle — which is also the chunk's centre, so
    /// the number is checkable by hand rather than only by the code that produces it.
    @Test("The rim is the mean elevation around the outline")
    func measuresTheRim() {
        let datum = GroundDatum.measured(
            boundary: DioramaBoundary.make(shape: .circular, extent: extent),
            heightField: rampField()
        )
        #expect(abs(datum.rim - 250) < 1.0, "A symmetric ramp averages to its midpoint, got \(datum.rim)")
    }

    /// Weighted by edge length, because a real outline crowds its vertices wherever the coastline is
    /// fiddly. Here one long edge crosses the low ground and a cluster of short ones sits on the
    /// high: an unweighted mean over the vertices would let the cluster speak for the loop.
    @Test("A crowded stretch of outline does not speak for the whole loop")
    func theRimIsWeightedByEdgeLength() {
        // A square, with the eastern (high) side subdivided into many short edges.
        var ring: [SIMD2<Float>] = [SIMD2(-0.4, -0.4), SIMD2(0.4, -0.4)]
        for step in 1..<16 {
            ring.append(SIMD2(0.4, -0.4 + 0.8 * Float(step) / 16))
        }
        ring.append(contentsOf: [SIMD2(0.4, 0.4), SIMD2(-0.4, 0.4)])
        let boundary = DioramaBoundary(vertices: ring)
        let field = rampField()
        let datum = GroundDatum.measured(boundary: boundary, heightField: field)

        let unweighted = ring
            .map { field.rawElevation(atX: $0.x, z: $0.y) }
            .reduce(0, +) / Float(ring.count)

        // The loop is symmetric in ground, so the honest answer is the ramp's midpoint. The
        // unweighted mean is dragged east by the subdivision, which is the failure this rules out.
        #expect(abs(datum.rim - 250) < 5, "Weighted mean should sit at the ramp's middle, got \(datum.rim)")
        #expect(unweighted - datum.rim > 20,
                "The fixture has to actually skew an unweighted mean or this measures nothing")
    }
}
