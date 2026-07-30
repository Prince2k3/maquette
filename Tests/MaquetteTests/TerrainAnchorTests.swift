import Foundation
import Testing
import simd
@testable import Maquette

@Suite("Terrain Anchor Tests")
struct TerrainAnchorTests {
    private static let grandCanyon = Coordinate(latitude: 36.0544, longitude: -112.1401)

    private func anchor(zoom: Int = 12, extent: Float = 1.44, radius: Double = 9000) -> TerrainAnchor {
        TerrainAnchor(
            centeredOn: Self.grandCanyon,
            zoom: zoom,
            extent: SIMD2(extent, extent),
            radiusMeters: radius
        )
    }

    @Test("Diorama and tile space round-trip")
    func roundTrip() {
        let anchor = anchor()
        for point in [SIMD2<Double>(0, 0), SIMD2(0.3, -0.42), SIMD2(-1.7, 2.9)] {
            let back = anchor.dioramaPoint(forTilePoint: anchor.tilePoint(forDioramaX: point.x, z: point.y))
            #expect(simd_distance(back, point) < 1e-9)
        }
    }

    @Test("A geographic anchor puts its coordinate at the diorama origin")
    func centerSitsAtOrigin() {
        let point = anchor().dioramaPoint(for: Self.grandCanyon)
        #expect(simd_length(point) < 1e-9)
    }

    @Test("The anchor's scale matches the configured geographic scale")
    func scaleMatchesConfiguration() {
        // Half the extent should span the radius on the ground, which is what `geographicScale`
        // promises everywhere else in the library.
        let extent: Float = 1.44
        let radius: Double = 9000
        let anchor = anchor(extent: extent, radius: radius)

        let east = anchor.coordinate(forDioramaX: Double(extent) / 2, z: 0)
        let metersEast = Turf.distance(from: Self.grandCanyon, to: east)
        // Mercator stretches with latitude, so the east-west span is exact only at the anchor's
        // own latitude — which is where this samples.
        #expect(abs(metersEast - radius) / radius < 0.01)
    }

    @Test("Shifting the anchor by whole tiles leaves the ground where it was")
    func shiftIsExact() {
        // This is what keeps panning from running out of precision: the offset never grows,
        // because whole tiles of it are absorbed into the anchor instead.
        let anchor = anchor()
        let perTile = anchor.dioramaMetersPerTile
        let shift = SIMD2(3, -2)
        let shifted = anchor.shifted(byTiles: shift)

        // Moving the anchor forward by whole tiles is cancelled by moving the point back by the
        // same distance, which is the pairing a pan uses: the offset sheds a tile, the anchor
        // takes it on.
        let point = SIMD2<Double>(0.21, -0.07)
        let moved = point - SIMD2(Double(shift.x) * perTile.x, Double(shift.y) * perTile.y)

        let before = anchor.tilePoint(forDioramaX: point.x, z: point.y)
        let after = shifted.tilePoint(forDioramaX: moved.x, z: moved.y)
        #expect(simd_distance(before, after) < 1e-9)
    }

    @Test("A mosaic anchor reproduces the mapping it replaced")
    func mosaicAnchorMatchesOldMapping() {
        // The old height field stretched whatever tiles were loaded across the extent. That is
        // still the right mapping for a chunk whose tiles never change, so it has to come out of
        // the anchor unchanged — otherwise every fixed diorama shifts.
        let extent = SIMD2<Float>(1.44, 1.44)
        let minTile = SIMD2(689, 1_601)
        let tilesWide = 5
        let tilesTall = 4
        let anchor = TerrainAnchor(
            mosaicMinTile: minTile,
            tilesWide: tilesWide,
            tilesTall: tilesTall,
            extent: extent,
            zoom: 12
        )

        for x in stride(from: Float(-0.72), through: 0.72, by: 0.09) {
            for z in stride(from: Float(-0.72), through: 0.72, by: 0.09) {
                // What the height field used to compute, verbatim.
                let nx = (Double(x) + Double(extent.x) / 2) / Double(extent.x)
                let nz = (Double(z) + Double(extent.y) / 2) / Double(extent.y)
                let expected = SIMD2(nx * Double(tilesWide), nz * Double(tilesTall))

                let tile = anchor.tilePoint(forDioramaX: Double(x), z: Double(z))
                let inWindow = tile - SIMD2(Double(minTile.x), Double(minTile.y))
                #expect(simd_distance(inWindow, expected) < 1e-12)
            }
        }
    }
}
