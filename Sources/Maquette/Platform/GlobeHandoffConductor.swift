import Foundation
import os
import RealityKit
import SwiftUI

/// The camera-independent half of the globe handoff, shared by every platform view.
///
/// The handoff's *mechanics* — the transition state machine, its animation clock, the crossfade,
/// and the relocation hold — are the same whether the scene is framed by an orbit camera (iOS,
/// macOS) or by the user's own head (visionOS). What differs per platform is only the *framing
/// response*: what to do with the transition's progress. So the conductor owns the mechanics and
/// takes the framing as a closure, and the platform models cannot drift apart in the parts that
/// hid two bugs the last time they were maintained separately.
@MainActor
@Observable
final class GlobeHandoffConductor {
    var transition = GlobeTransition()

    /// The transition's own animation clock, kept apart from the route preview's: the two run
    /// independently and sharing one date would have each of them consuming the other's elapsed time.
    var lastTransitionDate: Date?
    var legStart: Date?
    var legSteps = 0

    /// Retained so cancellation can be awaited by a caller coordinating another scene operation.
    private(set) var relocationTask: Task<Void, Never>?
    private var relocationRevision = 0

    /// An application ground command takes ownership of the scene from a globe journey.
    func cancelRelocation() {
        relocationRevision += 1
        relocationTask?.cancel()
        relocationTask = nil
        transition.reset()
        lastTransitionDate = nil
    }

    private let logger = Logger(maquette: "GlobeHandoff")

    /// Advances whichever leg of the handoff is playing, then reapplies the caller's framing.
    ///
    /// **The clock is cleared by the step that ends the leg, not by a later tick that finds nothing
    /// animating.** There is no later tick: the timeline is paused the moment `isAnimating` goes
    /// false, so a date left behind here survives however long the scene sits settled and arrives as
    /// the *next* leg's first elapsed time. That is a handoff which plays properly the first time and
    /// snaps thereafter — and it reads as the pinch deciding, because a user who cycles is a user
    /// who pinches hard.
    func advance(at date: Date, applyFrames: () -> Void) {
        guard transition.isAnimating else {
            lastTransitionDate = nil
            return
        }
        guard let last = lastTransitionDate else {
            lastTransitionDate = date
            legStart = date
            legSteps = 0
            return
        }
        lastTransitionDate = date
        legSteps += 1
        transition.advance(by: Float(date.timeIntervalSince(last)))
        if !transition.isAnimating {
            lastTransitionDate = nil
            // A leg that took one step is a leg that snapped, and on screen that is indistinguishable
            // from a handoff nobody asked to be gradual. Logged with its step count because the
            // difference between playing and jumping is not visible in a still.
            let seconds = legStart.map { date.timeIntervalSince($0) } ?? 0
            logger.debug("""
                Globe handoff settled at \(self.transition.progress, format: .fixed(precision: 0)) \
                after \(self.legSteps) steps over \(seconds, format: .fixed(precision: 2)) s
                """)
        }
        applyFrames()
    }

    /// Applies the cross-fade, and keeps a fully faded half out of the render entirely.
    func applyVisibility(store: DioramaStore) {
        if let entity = store.dioramaEntity {
            Self.applyVisibility(to: entity, opacity: transition.chunkOpacity)
        }
        if let globe = store.globe {
            Self.applyVisibility(to: globe, opacity: transition.globeOpacity)
        }
    }

    /// Reapplying an unchanged parent component dirties the whole photorealistic subtree.
    /// A fully opaque entity already has the correct default without an opacity component.
    static func applyVisibility(to entity: Entity, opacity: Float) {
        let enabled = opacity > DioramaSceneRig.minimumVisibleOpacity
        if entity.isEnabled != enabled { entity.isEnabled = enabled }
        let previous = entity.components[OpacityComponent.self]?.opacity ?? 1
        if previous != opacity { entity.components.set(OpacityComponent(opacity: opacity)) }
    }

    /// Rebuilds the chunk at whatever the globe was spun to.
    ///
    /// Fired as soon as the zoom starts coming back in rather than when it finishes, so the new
    /// ground is fetched during the dissolve instead of after it.
    ///
    /// The landing is the dock's own coordinate rather than whatever the camera happens to face,
    /// because steering *re-docks* — spinning the world puts the aimed-at ground at the sphere's
    /// top, which is where the chunk will be rebuilt. Asking the camera instead makes the landing
    /// depend on the tilt at the single frame progress leaves 1, and that tilt is mid-unwind by
    /// then: measured, half a degree short of overhead, which is 42 km of ground and enough to
    /// relocate a chunk nobody asked to move.
    ///
    /// - Parameters:
    ///   - store: The store whose chunk is being relocated.
    ///   - content: Content to re-apply once the new ground is in hand.
    ///   - afterLoad: The platform's own response to the rebuilt chunk (re-framing a camera on the
    ///     orbit platforms; nothing on visionOS, which has no camera to re-aim).
    ///   - applyFrames: The platform's framing + visibility application, run when the hold starts
    ///     and again when it resolves.
    func relocate(
        store: DioramaStore,
        content: DioramaContentGroup?,
        latestContent: (() -> DioramaContentGroup?)? = nil,
        afterLoad: @escaping () -> Void,
        applyFrames: @escaping () -> Void
    ) {
        guard let dock = store.globeDock else {
            logger.debug("Came back from the globe with nothing docked; keeping the chunk")
            return
        }
        let landing = dock.coordinate
        let current = Coordinate(store.configuration.center)
        // Straight back to where they started; the chunk in hand is already the right one. Logged
        // because it is indistinguishable on screen from a relocation that never fired at all.
        let travelled = Turf.distance(from: current, to: landing)
        guard travelled > store.configuration.radiusMeters / 4 else {
            logger.debug("Came back onto the same ground (\(travelled, format: .fixed(precision: 0)) m); keeping the chunk")
            return
        }
        // The globe carries the scene for the whole rebuild, which the gesture knows nothing about:
        // `relocate` nils the chunk entity from its first line to its last, so a crossfade run off
        // the input's own clock hands back to nothing — the globe finishes fading half way through
        // the fetch, and the new chunk appears at full opacity with no dissolve at all.
        transition.beginHold()
        lastTransitionDate = nil
        applyFrames()
        relocationRevision += 1
        let revision = relocationRevision
        relocationTask?.cancel()
        let storeRevision = store.beginNavigationRequest()
        relocationTask = Task {
            guard storeRevision == store.navigationRevision, !Task.isCancelled else { return }
            let generation = store.loadGeneration
            await store.relocate(to: landing)
            guard !Task.isCancelled, revision == relocationRevision,
                  store.loadGeneration == generation + 1, storeRevision == store.navigationRevision else { return }
            relocationTask = nil
            if let latestContent { store.applyContent(latestContent()) } else { store.applyContent(content) }
            afterLoad()
            if case .failed = store.loadingState {
                // Nothing to hand back to. Staying on the globe keeps the failure legible — and the
                // overlay stops being suppressed, so the error surfaces.
                transition.abandonHold()
            } else {
                transition.endHold()
            }
            applyFrames()
        }
    }
}
