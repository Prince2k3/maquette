#if MAQUETTE_PROFILING && (os(iOS) || os(macOS))
import Foundation
import os

/// Opt-in capture input, compiled out of normal library builds. Drives the same intent methods
/// as the gesture adapters; it measures rendered workloads, not hardware touch arbitration.
@MainActor
extension OrbitDioramaModel {
    func runProfileTour() async {
        guard ProcessInfo.processInfo.environment["MAQUETTE_PROFILE"] == "1" else { return }
        let logger = Logger(maquette: "ProfileTour")
        let signposter = OSSignposter(logger: Logger(maquette: "PointsOfInterest"))
        let workload = ProcessInfo.processInfo.environment["MAQUETTE_WORKLOAD"] ?? "unknown"
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(90))
        do {
            while store.loadingState != .loaded {
                guard clock.now < deadline else { logger.error("PROFILE terrain load timed out"); return }
                try await Task.sleep(for: .milliseconds(100))
            }
            if let root = store.dioramaEntity as? DioramaEntity { await root.overlayRenderer.waitUntilIdle() }
            try await Task.sleep(for: .seconds(8))
            logger.notice("PROFILE ready workload=\(workload, privacy: .public) viewport=\(self.viewSize.width)x\(self.viewSize.height)")
            for (name, phase) in [("Pan" as StaticString, 0), ("GroundZoom" as StaticString, 1), ("CameraZoom" as StaticString, 2)] {
                try Task.checkCancellation()
                let state = signposter.beginInterval(name, id: signposter.makeSignpostID(), "\(workload, privacy: .public)")
                logger.notice("PROFILE phaseBegin=\(String(describing: name), privacy: .public) workload=\(workload, privacy: .public)")
                let start = clock.now
                var previous = SIMD2<Float>.zero
                var tick = 0, missed = 0, scheduledTick = 1
                var intervals: [Double] = []
                var last = start
                var completed = false
                var overlaySamples = 0, hiddenOverlaySamples = 0, incoherentSurfaceSamples = 0
                let renderer = (store.dioramaEntity as? DioramaEntity)?.overlayRenderer
                let buildsAtStart = renderer?.geometryBuildCount ?? 0
                let presentationsAtStart = renderer?.panPresentationCount ?? 0
                defer {
                    if phase == 0 { primaryDrag(dx: -previous.x, dy: -previous.y) }
                    else { _ = zoomInput(-previous.x, target: phase == 1 ? .ground : .camera) }
                    endInteraction()
                    if !completed { signposter.endInterval(name, state, "completed=false") }
                }
                while true {
                    try Task.checkCancellation()
                    let now = clock.now
                    let elapsed = start.duration(to: now)
                    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    guard seconds < 10 else { break }
                    if let renderer {
                        for record in renderer.records.values {
                            overlaySamples += 1
                            if !record.entity.isEnabled { hiddenOverlaySamples += 1 }
                            else if let terrain = (store.dioramaEntity as? DioramaEntity)?.terrain,
                                    (record.appliedKey?.context.pan != terrain.presentedPanOffset
                                     || record.appliedKey?.context.revision != terrain.presentedSurfaceRevision) {
                                incoherentSurfaceSamples += 1
                            }
                        }
                    }
                    let angle = seconds * .pi * 4 / 10
                    let value: SIMD2<Float>
                    if phase == 0 {
                        value = .init(Float(sin(angle) * viewSize.width * 0.06), Float(sin(angle) * viewSize.height * 0.03))
                    } else {
                        value = .init(Float((1 - cos(angle)) * (phase == 1 ? 2 : 4)), 0)
                    }
                    let delta = value - previous
                    if phase == 0 { primaryDrag(dx: delta.x, dy: delta.y) }
                    else { _ = zoomInput(delta.x, target: phase == 1 ? .ground : .camera) }
                    previous = value
                    let gap = last.duration(to: now)
                    intervals.append(Double(gap.components.seconds) * 1000 + Double(gap.components.attoseconds) / 1e15)
                    last = now; tick += 1
                    let afterInput = start.duration(to: clock.now)
                    let afterSeconds = Double(afterInput.components.seconds) + Double(afterInput.components.attoseconds) / 1e18
                    let nextTick = max(scheduledTick, Int(afterSeconds * 60) + 1)
                    missed += nextTick - scheduledTick
                    scheduledTick = nextTick + 1
                    // Skip missed deadlines; never burst several inputs to catch up.
                    try await clock.sleep(until: start.advanced(by: .seconds(Double(nextTick) / 60)))
                }
                if phase == 0 { primaryDrag(dx: -previous.x, dy: -previous.y) }
                else { _ = zoomInput(-previous.x, target: phase == 1 ? .ground : .camera) }
                previous = .zero
                completed = true
                endInteraction()
                signposter.endInterval(name, state, "ticks=\(tick) missed=\(missed) completed=true")
                logger.notice("PROFILE phase=\(String(describing: name), privacy: .public) workload=\(workload, privacy: .public) ticks=\(tick) missed=\(missed) maxInputGapMs=\(intervals.max() ?? 0) completed=true")
                logger.notice("PROFILE overlaySamples=\(overlaySamples) hiddenOverlaySamples=\(hiddenOverlaySamples) completedBuilds=\((renderer?.geometryBuildCount ?? 0) - buildsAtStart) phase=\(String(describing: name), privacy: .public) incoherentSurfaceSamples=\(incoherentSurfaceSamples) panPresentations=\((renderer?.panPresentationCount ?? 0) - presentationsAtStart)")
                try await Task.sleep(for: .seconds(2))
            }
            logger.notice("PROFILE complete workload=\(workload, privacy: .public)")
        } catch {
            endInteraction()
            logger.notice("PROFILE stopped workload=\(workload, privacy: .public)")
        }
    }
}
#endif
