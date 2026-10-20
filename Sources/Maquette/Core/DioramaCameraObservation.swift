import Foundation

/// Keeps orbit observation independent of geographic navigation and camera binding write-back.
@MainActor
final class DioramaCameraObservation {
    var action: DioramaCameraObservationAction?
    var isTransitioning: (() -> Bool)?
    private var interactions: Set<DioramaInteractionSource> = []
    private var isInteracting: Bool { !interactions.isEmpty }
    private var lastCamera: DioramaCamera?
    private var changeRevision = 0
    private var endedRevision = 0
    private var origin: DioramaNavigationContext.Origin = .programmatic
    private var actionInProgress = false
    private var settleTask: Task<Void, Never>?

    func began(_ source: DioramaInteractionSource = .drag) {
        interactions.insert(source)
        settleTask?.cancel()
    }

    func ended(_ source: DioramaInteractionSource = .drag) {
        interactions.remove(source)
        if !isInteracting && !actionInProgress { scheduleEnd() }
    }

    func changed(_ camera: DioramaCamera, origin: DioramaNavigationContext.Origin, force: Bool = false) {
        guard force || lastCamera != camera else { return }
        lastCamera = camera
        changeRevision += 1
        self.origin = origin
        if action?.frequency == .continuous {
            action?.action(DioramaCameraChangeContext(camera: camera, phase: .changing, origin: origin))
        }
        if !isInteracting && !actionInProgress { scheduleEnd() }
    }

    /// An elapsed-time action owns its end; a quiet input interval is not completion.
    func beganAction() {
        settleTask?.cancel()
        actionInProgress = true
    }

    func finishedAction(_ camera: DioramaCamera, cancelled: Bool = false) {
        guard actionInProgress else { return }
        actionInProgress = false
        settleTask?.cancel()
        lastCamera = camera
        endedRevision = changeRevision
        action?.action(DioramaCameraChangeContext(camera: camera,
            phase: cancelled ? .cancelled : .ended, origin: origin))
    }

    private func scheduleEnd() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            while !Task.isCancelled, self.isTransitioning?() == true {
                try? await Task.sleep(for: .milliseconds(32))
            }
            guard !Task.isCancelled, !self.isInteracting, !self.actionInProgress,
                  let camera = self.lastCamera, self.changeRevision != self.endedRevision else { return }
            self.endedRevision = self.changeRevision
            self.action?.action(DioramaCameraChangeContext(camera: camera, phase: .ended, origin: self.origin))
        }
    }

    deinit { settleTask?.cancel() }
}
