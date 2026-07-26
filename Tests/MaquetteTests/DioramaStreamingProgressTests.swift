import Testing
@testable import Maquette

@Suite("Streaming Progress Tests")
struct DioramaStreamingProgressTests {
    @Test("Nothing loaded and nothing wanted yet reads as zero while streaming")
    func emptyWhileStreaming() {
        let progress = DioramaStreamingProgress(tilesLoaded: 0, tilesPending: 0, isStreaming: true)
        #expect(progress.fractionComplete == 0)
    }

    @Test("Nothing loaded and nothing wanted reads as complete once settled")
    func emptyWhenSettled() {
        // A region the tileset has no coverage for loads no tiles and never will. Reporting it as
        // 0% would leave a bar that can never fill.
        let progress = DioramaStreamingProgress(tilesLoaded: 0, tilesPending: 0, isStreaming: false)
        #expect(progress.fractionComplete == 1)
    }

    @Test("Fraction is loaded over everything currently known")
    func fractionCountsKnownWork() {
        let progress = DioramaStreamingProgress(tilesLoaded: 30, tilesPending: 10, isStreaming: true)
        #expect(abs(progress.fractionComplete - 0.75) < 1e-9)
    }

    @Test("Fraction reaches one when nothing is outstanding")
    func fractionCompletesWithNothingPending() {
        let progress = DioramaStreamingProgress(tilesLoaded: 40, tilesPending: 0, isStreaming: false)
        #expect(progress.fractionComplete == 1)
    }

    @Test("Discovering new work can move the fraction backwards")
    func fractionCanRegress() {
        // Documented behaviour, not a defect: a 3D Tiles tree is discovered as it is walked, so a
        // tile that arrives can name children nothing had heard of. Anything relying on this being
        // monotonic would be relying on the total being knowable up front, which it is not.
        let before = DioramaStreamingProgress(tilesLoaded: 9, tilesPending: 1, isStreaming: true)
        let after = DioramaStreamingProgress(tilesLoaded: 10, tilesPending: 40, isStreaming: true)
        #expect(after.fractionComplete < before.fractionComplete)
    }
}
