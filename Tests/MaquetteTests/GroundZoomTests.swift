import Foundation
import Testing
@testable import Maquette

/// The arithmetic behind zooming the map rather than the camera.
///
/// The mapping itself is pinned in `TerrainAnchorTests`; what is left here is the ladder of tile
/// levels the zoom walks, which is the part that decides whether the chunk ever refetches and how
/// far the mosaic is stretched while it waits.
@Suite("Ground zoom")
struct GroundZoomTests {
    @Test("One level answers one doubling")
    func aLevelPerDoubling() {
        #expect(DioramaStore.desiredTileZoom(base: 12, scale: 1) == 12)
        #expect(DioramaStore.desiredTileZoom(base: 12, scale: 2) == 11)
        #expect(DioramaStore.desiredTileZoom(base: 12, scale: 4) == 10)
        #expect(DioramaStore.desiredTileZoom(base: 12, scale: 64) == 6)
    }

    @Test("The mosaic is never stretched by more than about √2")
    func roundingCentresTheStretch() {
        // Rounding rather than flooring is the whole point: at 1.9× the tiles in hand are nearly two
        // levels too fine to stretch, so the level moves before the softness is visible rather than
        // after. The test is that the *residual* stretch stays inside √2 across the range.
        let base = 12
        for step in 0...80 {
            let scale = Float(exp2(Double(step) / 10))
            let level = DioramaStore.desiredTileZoom(base: base, scale: scale)
            let residual = scale / Float(exp2(Double(base - level)))
            #expect(residual > 1 / 1.4143 && residual < 1.4143)
        }
    }

    @Test("It never asks for detail the fetch never established")
    func neverGoesFinerThanTheLoadedLevel() {
        // Zooming *in* magnifies the tiles in hand. Asking for a finer level would be asking for
        // ground the chunk never fetched at that resolution, and the roller would fetch it — turning
        // a resample into a download for detail the caller never configured.
        #expect(DioramaStore.desiredTileZoom(base: 12, scale: 0.5) == 12)
        #expect(DioramaStore.desiredTileZoom(base: 12, scale: 0.25) == 12)
    }

    @Test("It stops where the globe takes over")
    func stopsAtTheWorldLevel() {
        // Past this the flat cut stops reading as a piece of the earth, which is the moment the
        // handoff exists for — so the ladder ends here rather than at Mercator's own level 0.
        #expect(DioramaStore.desiredTileZoom(base: 12, scale: 1_048_576) == DioramaStore.worldTileZoom)
        // A chunk that loaded coarser than the world level has nowhere to go, and must not be handed
        // a level finer than it fetched by the clamp meant to keep it coarse.
        #expect(DioramaStore.desiredTileZoom(base: 3, scale: 64) == 3)
    }
}

/// The breadth a chunk comes back at after the globe has carried the scene.
///
/// A departure is a journey out — widen, re-level, widen again — and the way home is the same steps
/// in reverse, so the chunk that reappears has to be cut at the breadth the user left at. What that
/// costs if it is dropped is the whole return: `load()` builds every chunk at its configuration's own
/// radius, and from the ceiling that is a couple of hundred times too narrow.
@Suite("Returning from the globe")
struct GlobeReturnZoomTests {
    /// The scale the ground zoom runs out at, which is where the globe takes the gesture on — so it
    /// is also the scale nearly every relocation departs from.
    private func ceilingScale(base: Int) -> Float {
        max(exp2(Float(base - DioramaStore.worldTileZoom)), 1)
    }

    @Test("A chunk restored to the departure scale spans the ground the globe was showing")
    func theBreadthComesBack() {
        // The configuration's radius does not change across a relocate, so the scale is the whole of
        // the difference between the chunk the user left and the chunk they are handed back.
        let configured = 5_000.0
        let scale = ceilingScale(base: 12)
        #expect(configured * Double(scale) == 1_280_000)
        // What dropping it costs, stated as the thing the user sees: five kilometres of ground where
        // they were looking at more than a thousand.
        #expect(configured * Double(scale) / configured == 256)
    }

    @Test("Restoring the scale asks for the level the departure ended on, in one step")
    func theRestoreLandsOnTheDepartureLevel() {
        // The re-level ladder is walked a level at a time on the way out, because the pinch arrives a
        // step at a time. A restore is one jump, and it has to resolve straight to the far end rather
        // than eight fetches down a ladder the user is waiting on.
        for base in [10, 11, 12, 13] {
            let scale = ceilingScale(base: base)
            #expect(DioramaStore.desiredTileZoom(base: base, scale: scale) == DioramaStore.worldTileZoom)
        }
    }

    /// What a roll costs if it is allowed out at the level the restore is already replacing.
    ///
    /// The restore lands the whole scale in one step, so between it and the re-level the chunk is
    /// reading tiles a couple of hundred levels' worth of ground too fine — and a roll issued in that
    /// window asks for its margin in tiles that now span almost none of the chunk. Every one of them
    /// is discarded on arrival, because a re-level fetches its own window from scratch.
    @Test("A roll taken before the re-level would ask for the whole journey in fine tiles")
    func aRollAtTheStaleLevelIsAFetchStorm() {
        let base = TerrainAnchor(
            centeredOn: Coordinate(latitude: 36.0544, longitude: -112.1401),
            zoom: 12,
            extent: SIMD2(0.8, 0.8),
            radiusMeters: 5_000
        )
        let scale = ceilingScale(base: 12)

        func tilesAcross(_ anchor: TerrainAnchor) -> Double {
            0.8 / anchor.dioramaMetersPerTile.x
        }

        // What the chunk stands on once the re-level has landed: a handful of world-level tiles.
        let settled = tilesAcross(base.atZoom(DioramaStore.worldTileZoom).scaled(by: Double(scale)))
        #expect(settled < 4)

        // And what it would ask for in the gap, at the level it has not yet left. Squared, because a
        // window is two-dimensional — which is where the four figures come from.
        let stale = tilesAcross(base.scaled(by: Double(scale)))
        #expect(stale / settled == Double(scale))
        #expect(stale * stale > 1_000)

        // So the gate is the same question the re-level asks itself: the level the scale wants is not
        // the level the tiles are at, and until it is there is nothing worth rolling for.
        #expect(DioramaStore.desiredTileZoom(base: 12, scale: scale) != 12)
    }

    /// Why the restore goes through the ground zoom rather than being fetched at the coarse level
    /// directly, which would be cheaper: the limits are measured from the level the chunk *loaded*
    /// at, so loading coarse leaves nothing to zoom.
    @Test("Loading at the coarse level instead would leave the chunk unable to zoom at all")
    func theLimitsAreMeasuredFromTheLoadedLevel() {
        // The ladder a chunk loaded at its native level still has in front of it.
        #expect(exp2(Float(12 - DioramaStore.worldTileZoom)) == 256)
        // And what is left if the coarse level is where it loaded: one rung, which is none.
        #expect(exp2(Float(DioramaStore.worldTileZoom - DioramaStore.worldTileZoom)) == 1)
        // Nor could it re-level back in, for the same reason — it never asks finer than it fetched.
        #expect(DioramaStore.desiredTileZoom(base: DioramaStore.worldTileZoom, scale: 0.25)
            == DioramaStore.worldTileZoom)
    }
}

/// What a re-level must and must not change while the pinch it was triggered by carries on.
///
/// A re-level is the one thing in the library that changes *what a tile coordinate means*, and it
/// takes hundreds of milliseconds to fetch — during which the pinch keeps moving and a roll may
/// already be in flight against the level being replaced. Both of the things that can go wrong here
/// fail silently on screen (a plausible piece of ground, placed with complete confidence), so they
/// are pinned as arithmetic instead.
@Suite("Re-levelling")
struct RelevelTests {
    private static let grandCanyon = Coordinate(latitude: 36.0544, longitude: -112.1401)

    private func anchor(zoom: Int = 12) -> TerrainAnchor {
        TerrainAnchor(
            centeredOn: Self.grandCanyon,
            zoom: zoom,
            extent: SIMD2(0.8, 0.8),
            radiusMeters: 6000
        )
    }

    /// Why a re-level can swap the ground in whole with no teardown: at a fixed scale, the level is
    /// invisible to the mapping. Only which tiles are fetched changes.
    @Test("A change of level at the same scale names the same ground")
    func levelDoesNotMoveTheGround() {
        let base = anchor()
        for scale in [4.0, 8.0, 16.0] {
            let fine = base.atZoom(11).scaled(by: scale)
            let coarse = base.atZoom(9).scaled(by: scale)
            for point in [SIMD2<Double>(0, 0), SIMD2(0.31, -0.18), SIMD2(-0.4, 0.22)] {
                let a = fine.coordinate(forDioramaX: point.x, z: point.y)
                let b = coarse.coordinate(forDioramaX: point.x, z: point.y)
                #expect(Turf.distance(from: a, to: b) < 0.01)
            }
        }
    }

    /// The re-level's own bug, stated as a distance. The mapping used to be built before the fetch
    /// and applied after it, so the scale it carried was however far the pinch had got when the
    /// level was chosen — and the ground snapped back to that as the sharper tiles landed.
    @Test("A mapping built at the scale the fetch started at moves the ground")
    func aStaleScaleMovesTheGround() {
        let base = anchor()
        let issuedAt = 4.0    // the scale when the re-level was decided
        let landedAt = 5.6    // where the pinch had got to when the tiles arrived

        let point = SIMD2<Double>(0.3, -0.2)
        let live = base.atZoom(10).scaled(by: landedAt).coordinate(forDioramaX: point.x, z: point.y)
        let stale = base.atZoom(10).scaled(by: issuedAt).coordinate(forDioramaX: point.x, z: point.y)

        // Between a third and a half of the chunk's own radius — far too big to read as anything
        // but the map flinching, and in the middle of a gesture that is moving anyway.
        #expect(Turf.distance(from: live, to: stale) > 1000)

        // What the fix restates instead: the mapping in force when the tiles land, which is exactly
        // what a zoom step arriving a moment later would have produced.
        let applied = base.atZoom(10).scaled(by: landedAt)
        #expect(Turf.distance(
            from: applied.coordinate(forDioramaX: point.x, z: point.y), to: live
        ) < 0.01)
    }

    /// Why a roll in flight across a re-level has to be discarded rather than applied: a
    /// ``TerrainTileSet`` is keyed by tile coordinate with no level in the key, so the very same key
    /// names ground a continent away one level out.
    @Test("The same tile key names different ground at a different level")
    func aTileKeyIsMeaninglessWithoutItsLevel() {
        let fine = TileMath.tileXY(for: Self.grandCanyon, zoom: 12)
        let asIfCoarser = TileMath.coordinate(
            forTilePoint: SIMD2(Double(fine.x) + 0.5, Double(fine.y) + 0.5), zoom: 11
        )
        #expect(Turf.distance(from: Self.grandCanyon, to: asIfCoarser) > 1_000_000)
    }
}
