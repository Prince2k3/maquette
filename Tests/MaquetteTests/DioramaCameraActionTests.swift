import SwiftUI
import Testing
@testable import Maquette

@MainActor
@Suite("Scoped camera actions")
struct DioramaCameraActionTests {
    @Test func equalActionsReceiveIndependentIDsAndSupersede() throws {
        let host = CameraActionHost()
        host.capabilities = .orbit
        var received: [DioramaCameraRequestID] = []
        var cancelled: [DioramaCameraRequestID] = []
        host.receive = { id, _ in received.append(id) }
        host.cancel = { cancelled.append($0) }
        let proxy = DioramaCameraProxy(host: host)
        guard case .accepted(let first) = proxy.setCamera(.init()),
              case .accepted(let second) = proxy.setCamera(.init()) else {
            Issue.record("Expected acceptance"); return
        }
        #expect(first != second)
        #expect(received == [first, second])
        #expect(cancelled == [first])
        #expect(proxy.result(for: first) == .cancelled(first))
        host.complete(first, camera: .init(distance: 3))
        host.cancelRequest(first)
        #expect(host.activeRequest == second)
        host.complete(second, camera: .init(distance: 2))
        proxy.cancel()
        #expect(proxy.result(for: second) == .completed(second, .init(distance: 2)))
    }

    @Test func synchronousCompletionRetainsTerminalResult() {
        let host = CameraActionHost()
        host.capabilities = .orbit
        host.receive = { id, _ in host.complete(id, camera: .init()) }
        let proxy = DioramaCameraProxy(host: host)
        guard case .accepted(let id) = proxy.reset() else { Issue.record("Expected receipt"); return }
        #expect(proxy.activeRequest == nil)
        #expect(proxy.result(for: id) == .completed(id, .init()))
    }

    @Test func invalidRequestsDoNotCancelPendingActions() {
        let host = CameraActionHost()
        host.capabilities = .orbit
        host.receive = { _, _ in }
        let proxy = DioramaCameraProxy(host: host)
        guard case .accepted(let id) = proxy.reset() else { Issue.record("Expected receipt"); return }
        #expect(proxy.setCamera(.init(pitch: .degrees(91))) == .invalidRequest)
        #expect(proxy.setCamera(.init(heading: .radians(.nan))) == .invalidRequest)
        #expect(proxy.setCamera(.init(distance: .infinity)) == .invalidRequest)
        #expect(proxy.setCamera(.init(focus: .coordinate(.init(latitude: 91, longitude: 0), altitude: .absolute))) == .invalidRequest)
        #expect(proxy.setCamera(.init(focus: .coordinate(.init(latitude: 0, longitude: 0, altitude: .nan), altitude: .absolute))) == .invalidRequest)
        #expect(proxy.fit(.contentIDs([])) == .invalidRequest)
        #expect(proxy.fit(.contentIDs([""])) == .invalidRequest)
        #expect(proxy.fit(.bounds(.init(west: 0, south: 30, east: 10, north: 20))) == .invalidRequest)
        #expect(proxy.fit(.chunk, padding: .init(top: -1, leading: 0, bottom: 0, trailing: 0)) == .invalidRequest)
        #expect(proxy.fit(.chunk, transition: .easeInOut(duration: .nan)) == .invalidRequest)
        #expect(proxy.activeRequest == id)
    }

    @Test func unavailableAndTerminalFailures() {
        let host = CameraActionHost()
        let proxy = DioramaCameraProxy(host: host)
        #expect(proxy.reset() == .unavailable)
        host.capabilities = .orbit
        host.receive = { _, _ in }
        guard case .accepted(let id) = proxy.fit(.chunk) else { Issue.record("Expected receipt"); return }
        host.complete(id, result: .requiresGroundNavigation(id))
        #expect(proxy.lastResult == .requiresGroundNavigation(id))
        guard case .accepted(let next) = proxy.fit(.chunk) else { Issue.record("Expected receipt"); return }
        host.complete(next, result: .constrainedFit(next))
        #expect(proxy.result(for: next) == .constrainedFit(next))
    }

    @Test func ownershipAndIndependentHosts() {
        final class Owner {}
        let owner = Owner(), other = Owner()
        let first = CameraActionHost(), second = CameraActionHost()
        #expect(first.claim(owner))
        #expect(first.claim(owner))
        #expect(!first.claim(other))
        #expect(second.claim(other))
        first.capabilities = .orbit
        first.receive = { _, _ in }
        _ = first.submit(.reset)
        first.release(owner: other)
        #expect(first.activeRequest != nil)
        first.release(owner: owner)
        #expect(first.activeRequest == nil)
        #expect(first.claim(other))
        #expect(second.capabilities == .unavailable)
    }

    @Test func nestedSubmissionDuringCancellationWins() {
        let host = CameraActionHost()
        host.capabilities = .orbit
        var received: [DioramaCameraRequestID] = []
        var cancelled: [DioramaCameraRequestID] = []
        var nested: DioramaCameraRequestID?
        host.receive = { id, _ in received.append(id) }
        guard case .accepted(let first) = host.submit(.reset) else {
            Issue.record("Expected first action"); return
        }
        host.cancel = { id in
            cancelled.append(id)
            if id == first, case .accepted(let id) = host.submit(.reset) { nested = id }
        }
        guard case .accepted(let outer) = host.submit(.reset), let nested else {
            Issue.record("Expected outer and nested receipts"); return
        }
        #expect(host.activeRequest == nested)
        #expect(received == [first, nested])
        #expect(cancelled == [first, outer])
        #expect(host.results[first] == .cancelled(first))
        #expect(host.results[outer] == .cancelled(outer))
        host.complete(nested, camera: .init())
        #expect(host.results[nested] == .completed(nested, .init()))
    }

    @Test func releaseDuringCancellationDetachesBeforeCallbacks() {
        final class Owner {}
        let owner = Owner()
        let host = CameraActionHost()
        #expect(host.claim(owner))
        host.capabilities = .orbit
        var received: [DioramaCameraRequestID] = []
        var cancelled: [DioramaCameraRequestID] = []
        var nested: DioramaCameraActionResult?
        host.receive = { id, _ in received.append(id) }
        guard case .accepted(let first) = host.submit(.reset) else {
            Issue.record("Expected first action"); return
        }
        host.cancel = { id in
            cancelled.append(id)
            if id == first {
                host.release(owner: owner)
            } else {
                nested = host.submit(.reset)
            }
        }
        guard case .accepted(let outer) = host.submit(.reset) else {
            Issue.record("Expected outer receipt"); return
        }
        #expect(received == [first])
        #expect(cancelled == [first, outer])
        #expect(nested == .unavailable)
        #expect(host.activeRequest == nil)
        #expect(host.results[first] == .cancelled(first))
        #expect(host.results[outer] == .cancelled(outer))
        #expect(host.capabilities == .unavailable)
        #expect(host.receive == nil)
    }

    @Test func boundedHistory() {
        let host = CameraActionHost()
        host.capabilities = .orbit
        host.receive = { _, _ in }
        for _ in 0..<200 { _ = host.submit(.reset) }
        #expect(host.results.count == 128)
        #expect(host.activeRequest != nil)
    }

    @Test func limitsAndPositionReadback() {
        #expect(DioramaCameraLimits(distance: 0...10) == nil)
        #expect(DioramaCameraLimits(distance: 1...Float.infinity) == nil)
        #expect(DioramaCameraLimits(pitchDegrees: -1...85) == nil)
        #expect(DioramaCameraLimits(pitchDegrees: 0...91) == nil)
        #expect(DioramaCameraLimits(pitchDegrees: 0...90, focusPolicy: .unrestricted) != nil)
        let camera = DioramaCamera(heading: .degrees(45), pitch: .zero, distance: 2)
        #expect(!DioramaCameraPosition.camera(camera).positionedByUser)
        #expect(DioramaCameraPosition.userPositioned(camera).positionedByUser)
        #expect(DioramaCameraPosition.userPositioned(camera).camera == camera)
    }
}
