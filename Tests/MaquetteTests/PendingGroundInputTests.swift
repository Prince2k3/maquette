import Testing
import simd
@testable import Maquette

@Suite("Pending ground input")
struct PendingGroundInputTests {
    @Test func mixedPanAndZoomRetainTheRequestedGeographicGround() throws {
        let base = TerrainAnchor(centeredOn: Coordinate(latitude: 36, longitude: -112),
            zoom: 12, extent: .init(repeating: 1), radiusMeters: 1000)
        let input = PendingGroundInput(pan: .init(0.2, -0.1), scale: 4)
        // Include a clamped scale and an unchanged/rejected request.
        for accepted: Float in [4, 2, 1] {
            let offset = try #require(input.pan(from: 1, to: accepted))
            let before = base.coordinate(forDioramaX: 0.2, z: -0.1)
            let after = base.scaled(by: Double(accepted)).coordinate(forDioramaX: Double(offset.x), z: Double(offset.y))
            #expect(abs(before.latitude - after.latitude) < 1e-7)
            #expect(abs(before.longitude - after.longitude) < 1e-7)
        }
    }

    @Test func zoomFactorsAccumulateOnTheLatestQueuedTargetAndCanReverse() {
        var input = PendingGroundInput()
        input.scale = input.zoomTarget(from: 1, by: 2)
        input.scale = input.zoomTarget(from: 1, by: 1.5)
        #expect(input.scale == 3)
        input.scale = input.zoomTarget(from: 1, by: 1 / 3)
        #expect(input.scale == 1)
        input = PendingGroundInput()
        #expect(input.pan(from: 1, to: 2) == nil)
        #expect(input.zoomTarget(from: 2, by: 1.5) == 3)
    }
}
