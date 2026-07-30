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
