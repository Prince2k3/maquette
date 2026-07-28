import Foundation
import Testing
import simd
@testable import Maquette

@Suite("Ground boxes")
struct GroundBoxTests {
    private func box(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) -> GroundBox {
        GroundBox(lo: SIMD2(x0, y0), hi: SIMD2(x1, y1))
    }

    /// The whole point of subtracting: a chunk that has slid asks for the strip it moved onto and
    /// not for the city it is already standing on. Measured by area, because that is what a wrong
    /// decomposition changes — piece counts can be right while the pieces are the wrong size.
    @Test func aTranslatedBoxAsksForTwoStrips() {
        let old = box(0, 0, 10, 10)
        let new = box(2, 3, 12, 13)
        let pieces = new.subtracting(old)

        #expect(pieces.count == 2)
        let area = pieces.reduce(Float.zero) { $0 + ($1.hi.x - $1.lo.x) * ($1.hi.y - $1.lo.y) }
        // 100 of the new box's 100 square meters overlap on an 8×7 patch.
        #expect(abs(area - (100 - 56)) < 1e-4)
    }

    /// Pieces that overlapped each other would fetch — and then draw — the same buildings twice.
    @Test func thePiecesCoverTheDifferenceExactlyAndDoNotOverlap() {
        let old = box(-1, -2, 4, 5)
        for new in [
            box(0, 0, 10, 10),        // partial overlap
            box(2, 2, 3, 3),          // wholly inside
            box(-5, -5, 20, 20),      // wholly containing
            box(-1, -2, 4, 5),        // identical
            box(100, 100, 110, 110)   // disjoint
        ] {
            let pieces = new.subtracting(old)

            var x = new.lo.x + 0.05
            while x < new.hi.x {
                var y = new.lo.y + 0.05
                while y < new.hi.y {
                    let point = SIMD2(x, y)
                    let covering = pieces.count { $0.contains(point) }
                    if old.contains(point) {
                        #expect(covering == 0, "\(point) is already held")
                    } else {
                        #expect(covering == 1, "\(point) is covered \(covering) times")
                    }
                    y += 0.25
                }
                x += 0.25
            }

            // And nothing outside the box being asked for.
            for piece in pieces {
                #expect(new.contains(piece))
            }
        }
    }

    @Test func aDisjointBoxIsAskedForWhole() {
        let pieces = box(20, 20, 30, 30).subtracting(box(0, 0, 10, 10))
        #expect(pieces == [box(20, 20, 30, 30)])
    }

    @Test func nothingIsAskedForWhenTheGroundIsAlreadyHeld() {
        #expect(box(2, 2, 4, 4).subtracting(box(0, 0, 10, 10)).isEmpty)
        #expect(box(0, 0, 10, 10).contains(box(2, 2, 4, 4)))
        #expect(!box(0, 0, 10, 10).contains(box(2, 2, 11, 4)))
    }

    @Test func expandingGrowsEverySide() {
        let grown = box(0, 0, 10, 10).expanded(by: SIMD2(1, 2))
        #expect(grown == box(-1, -2, 11, 12))
    }

    /// Z counts southward, so the corner at minimum Z is the *northern* one. Naming rather than
    /// sorting produces a box whose south is above its north, which a provider answers with nothing.
    @Test func geographicBoundsSurviveTheInvertedLatitude() {
        let anchor = TerrainAnchor(
            zoom: 14,
            originTile: SIMD2(2620.0, 6333.0),
            tilesPerDioramaMeter: SIMD2(1, 1)
        )
        let bounds = box(0.1, 0.1, 0.4, 0.4).geographicBounds(anchor: anchor)

        #expect(bounds.north > bounds.south)
        #expect(bounds.east > bounds.west)
        let corner = anchor.coordinate(forDioramaX: 0.1, z: 0.1)
        #expect(abs(corner.latitude - bounds.north) < 1e-9)
        #expect(abs(corner.longitude - bounds.west) < 1e-9)
    }
}

@Suite("Building refetch merging")
struct BuildingMergeTests {
    private func footprint(at centre: SIMD2<Float>, size: Float = 0.02)
        -> BuildingExtruder.PlanarFootprint {
        let lo = centre - SIMD2(repeating: size / 2)
        let hi = centre + SIMD2(repeating: size / 2)
        return BuildingExtruder.PlanarFootprint(
            outline: [lo, SIMD2(hi.x, lo.y), hi, SIMD2(lo.x, hi.y)],
            minCorner: lo,
            maxCorner: hi,
            heightMeters: 10
        )
    }

    private let held = GroundBox(lo: SIMD2(0, 0), hi: SIMD2(1, 1))
    private let target = GroundBox(lo: SIMD2(0.5, 0), hi: SIMD2(1.5, 1))

    /// A provider answers a strip with everything *touching* it, so a building just inside the
    /// ground already fetched comes back again. Kept twice it draws twice, at double the triangles
    /// and z-fighting with itself.
    @Test func aBuildingAlreadyHeldIsNotAddedTwice() {
        let existing = footprint(at: SIMD2(0.9, 0.5))
        let merged = BuildingExtruder.merge(
            [existing, footprint(at: SIMD2(1.2, 0.5))],
            into: [existing],
            covering: target,
            alreadyHeld: held
        )
        #expect(merged.count == 2)
    }

    /// The far side of the old region has been panned off, and remembering it means re-extruding it
    /// on every roll for the rest of the session.
    @Test func groundThePanHasLeftIsDropped() {
        let merged = BuildingExtruder.merge(
            [footprint(at: SIMD2(1.4, 0.5))],
            into: [footprint(at: SIMD2(0.1, 0.5)), footprint(at: SIMD2(0.8, 0.5))],
            covering: target,
            alreadyHeld: held
        )
        #expect(merged.count == 2)
        #expect(merged.allSatisfy { $0.minCorner.x >= 0.5 })
    }

    /// A footprint straddling the target's edge is still half inside it, and dropping it would
    /// leave a hole at the rim rather than at the frontier.
    @Test func aBuildingStraddlingTheEdgeIsKept() {
        let merged = BuildingExtruder.merge(
            [footprint(at: SIMD2(1.5, 0.5))],
            into: [],
            covering: target,
            alreadyHeld: held
        )
        #expect(merged.count == 1)
    }
}
