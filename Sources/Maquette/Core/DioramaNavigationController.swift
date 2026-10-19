import SwiftUI

enum DioramaInteractionSource: Hashable { case drag, zoom }

/// Synchronizes ground requests without feeding read-back into the loading pipeline.
@MainActor
final class DioramaNavigationController {
    var binding: Binding<DioramaGroundPosition>?
    var preservesGround = false
    var configuration: DioramaConfiguration?
    var action: DioramaNavigationAction?
    var camera: (() -> DioramaCamera?)?
    var isTransitioning: (() -> Bool)?
    private(set) var lastApplied: DioramaGroundPosition?
    private(set) var homeRegion: DioramaRegion?
    private var inputRegion: DioramaRegion?
    var isApplyingRequest: Bool { applyingCommand }

    func configureHome(_ region: DioramaRegion, followsInput: Bool) {
        if homeRegion == nil || (followsInput && inputRegion != region) { homeRegion = region }
        inputRegion = region
    }
    private var commandTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var revision = 0
    private var applyingCommand = false
    private var interactions: Set<DioramaInteractionSource> = []
    private var isInteracting: Bool { !interactions.isEmpty }
    private var origin: DioramaNavigationContext.Origin = .programmatic
    private var changeRevision = 0
    private var endedRevision = 0
    private var lastPublished: DioramaGroundPosition?

    func observe(_ store: DioramaStore) {
        store.groundDidChange = { [weak self, weak store] in
            guard let self, let store, !self.applyingCommand else { return }
            self.publish(from: store)
        }
    }

    /// Returns false for read-back and duplicate requests. An application command is absolute.
    @discardableResult
    func applyRequest(
        _ position: DioramaGroundPosition?,
        store: DioramaStore,
        content: @escaping () -> DioramaContentGroup?,
        writesRequest: Bool = false,
        afterLoad: @escaping () -> Void
    ) -> Bool {
        guard let position, position != lastApplied else { return false }
        guard position.region.radius.isFinite, position.region.radius > 0,
              position.region.center.latitude.isFinite, position.region.center.longitude.isFinite,
              abs(position.region.center.latitude) <= 90 else { return false }
        lastApplied = position
        homeRegion = position.region
        if writesRequest, binding?.wrappedValue != position { binding?.wrappedValue = position }
        revision += 1
        let requestRevision = revision
        let storeRevision = store.beginNavigationRequest()
        commandTask?.cancel()
        settleTask?.cancel()
        applyingCommand = true
        origin = .programmatic
        commandTask = Task { [weak self] in
            guard let self, !Task.isCancelled, requestRevision == self.revision,
                  storeRevision == store.navigationRevision else { return }
            var configuration = self.configuration ?? store.configuration
            configuration.center = position.region.center.clLocationCoordinate
            configuration.radiusMeters = position.region.radius
            configuration.usesGeographicAnchor = true
            let generation = store.loadGeneration
            await store.reload(configuration: configuration)
            guard !Task.isCancelled, requestRevision == self.revision else { return }
            self.applyingCommand = false
            guard generation + 1 == store.loadGeneration, storeRevision == store.navigationRevision else {
                self.commandTask = nil
                self.publish(from: store)
                return
            }
            self.commandTask = nil
            store.applyContent(content())
            afterLoad()
            self.publish(from: store)
        }
        return true
    }

    /// Invalidates a pending command before an authoritative style or region reload.
    func invalidateCommand() {
        origin = .programmatic
        revision += 1
        commandTask?.cancel()
        commandTask = nil
        applyingCommand = false
        settleTask?.cancel()
    }

    func interactionBegan(_ source: DioramaInteractionSource = .drag) {
        guard !applyingCommand else { return }
        interactions.insert(source)
        origin = .userInteraction
        settleTask?.cancel()
    }

    func interactionEnded(store: DioramaStore, source: DioramaInteractionSource = .drag) {
        interactions.remove(source)
        if !isInteracting { scheduleEnd(store: store) }
    }

    /// Wheel input has no end callback; inactivity defines the end of that input stream.
    func wheelInput() {
        guard !applyingCommand else { return }
        origin = .userInteraction
        settleTask?.cancel()
    }

    func publish(from store: DioramaStore) {
        guard !applyingCommand, case .loaded = store.loadingState else { return }
        let position = DioramaGroundPosition.resolved(
            store.visibleGroundRegion, positionedByUser: origin == .userInteraction
        )
        // Record before writing so SwiftUI's onChange never treats this as a new request.
        lastApplied = position
        if binding?.wrappedValue != position { binding?.wrappedValue = position }
        if lastPublished != position {
            lastPublished = position
            changeRevision += 1
            if action?.frequency == .continuous {
                action?.action(context(position, phase: .changing))
            }
        }
        if !isInteracting { scheduleEnd(store: store) }
    }

    private func context(
        _ position: DioramaGroundPosition, phase: DioramaNavigationContext.Phase
    ) -> DioramaNavigationContext {
        DioramaNavigationContext(position: position, camera: camera?(), phase: phase, origin: origin)
    }

    private func scheduleEnd(store: DioramaStore) {
        settleTask?.cancel()
        settleTask = Task { [weak self, weak store] in
            // Wait for the tail of a pan and wheel input before reporting a final value.
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, let store else { return }
            while !Task.isCancelled {
                if self.isInteracting || self.applyingCommand { return }
                if !store.hasPendingPan && self.isTransitioning?() != true { break }
                try? await Task.sleep(for: .milliseconds(32))
            }
            guard !Task.isCancelled, case .loaded = store.loadingState,
                  let position = self.lastApplied, self.changeRevision != self.endedRevision else { return }
            self.endedRevision = self.changeRevision
            self.action?.action(self.context(position, phase: .ended))
        }
    }

    deinit {
        commandTask?.cancel()
        settleTask?.cancel()
    }
}
