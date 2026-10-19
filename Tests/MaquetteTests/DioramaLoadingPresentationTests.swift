import Testing
@testable import Maquette

@Suite("Custom loading retry")
@MainActor
struct DioramaLoadingPresentationTests {
    @Test("Retry is scoped to the supplied failed load and ignores active phases")
    func retryScope() {
        var first = 0
        var second = 0
        let failed = DioramaLoadingContext(
            state: .failed(.networkFailure(message: "fixture")), streamingProgress: nil,
            retryAction: { first += 1 }
        )
        let other = DioramaLoadingContext(
            state: .failed(.networkFailure(message: "other")), streamingProgress: nil,
            retryAction: { second += 1 }
        )
        failed.retry()
        #expect(first == 1)
        #expect(second == 0)
        other.retry()
        #expect(second == 1)
        for state: DioramaLoadingState in [.idle, .loading, .loaded] {
            DioramaLoadingContext(state: state, streamingProgress: nil, retryAction: { first += 1 }).retry()
        }
        #expect(first == 1)
    }
}
