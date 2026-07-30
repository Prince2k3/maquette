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
