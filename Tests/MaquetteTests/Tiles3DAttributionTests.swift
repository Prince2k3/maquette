import Foundation
import Testing
@testable import Maquette

/// The per-tile copyright pipeline: parsed out of the GLB, aggregated over what is visible.
///
/// This is a licensing obligation, not a nicety — Google's terms require every source credited by
/// a tile in view to be displayed on screen, ordered by how many tiles credit it.
@Suite("3D Tiles Attribution Tests")
struct Tiles3DAttributionTests {

    @Test("Sources are counted across tiles and ordered most-credited first")
    func aggregationOrdersByCount() {
        let text = Tiles3DLODManager.aggregateAttribution(over: [
            "Google;Airbus",
            "Google;Maxar Technologies",
            "Google",
        ])
        #expect(text == "Google · Airbus · Maxar Technologies")
    }

    @Test("Semicolon-joined sources split, and whitespace is trimmed")
    func splittingAndTrimming() {
        let text = Tiles3DLODManager.aggregateAttribution(over: ["  Airbus ; ; Maxar  "])
        #expect(text == "Airbus · Maxar")
    }

    @Test("Ties order alphabetically so the line is stable frame to frame")
    func tiesAreStable() {
        let text = Tiles3DLODManager.aggregateAttribution(over: ["Zebra;Airbus"])
        #expect(text == "Airbus · Zebra")
    }

    @Test("No credited tiles means no line, not an empty one")
    func emptyIsNil() {
        #expect(Tiles3DLODManager.aggregateAttribution(over: []) == nil)
        #expect(Tiles3DLODManager.aggregateAttribution(over: [" ; "]) == nil)
    }
}
