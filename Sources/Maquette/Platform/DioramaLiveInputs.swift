import RealityKit
import SwiftUI

/// The platform-independent halves of `DioramaView`'s live inputs: region/style changes, and
/// marker selection. Shared by the orbit and volumetric models so the two cannot drift.
@MainActor
enum DioramaLiveInputs {
    /// Adopts a changed reload key: content re-applies in place; a changed region or style moves
    /// or rebuilds the substrate.
    ///
    /// A change to the region's *centre alone* is a relocation — the machinery the globe handoff
    /// already uses, which keeps the ground scale and refetches in place. Anything else (radius,
    /// shape, size, style) is a rebuild, since it changes what is fetched or how the solid is
    /// generated. Either way the view's identity never has to change, which is what retires the
    /// `.id(preset)` forced-reload pattern.
    static func applyReloadKey(
        _ key: DioramaViewInputs.ReloadKey,
        store: DioramaStore,
        content: DioramaContentGroup?,
        usesGeographicAnchor: Bool = false,
        beforeReload: @MainActor () -> Void = {},
        latestContent: (() -> DioramaContentGroup?)? = nil,
        afterLoad: @escaping @MainActor () -> Void
    ) {
        let current = store.configuration

        // Buildings *visibility* is a live toggle over entities already in hand, never worth a
        // rebuild — so it is normalized out of the substrate comparison and applied directly.
        var currentStyle = DioramaStyle(configuration: current)
        var targetStyle = key.style
        let targetVisibility = targetStyle.buildings?.isVisible
        let visibilityChanged = currentStyle.buildings?.isVisible != targetVisibility
        currentStyle.buildings?.isVisible = true
        targetStyle.buildings?.isVisible = true

        // In initial-only/bound navigation modes, geographic ownership belongs to the navigation
        // controller. The substituted region is the target for a genuine substrate rebuild, not
        // evidence that a visibility-only style update should relocate already panned/zoomed ground.
        let sameSubstrate = (usesGeographicAnchor || key.region.radius == current.radiusMeters)
            && key.shape == current.shape
            && key.physicalSize == current.physicalSize
            && currentStyle == targetStyle
        let sameCenter = usesGeographicAnchor || Coordinate(current.center) == key.region.center

        if sameSubstrate && sameCenter {
            if visibilityChanged, let targetVisibility {
                store.configuration.buildings?.isVisible = targetVisibility
                store.setBuildingsVisible(targetVisibility)
            }
            return
        }
        beforeReload()
        let revision = store.beginNavigationRequest()
        Task {
            guard revision == store.navigationRevision else { return }
            let generation = store.loadGeneration
            if sameSubstrate {
                await store.relocate(to: key.region.center)
            } else {
                var configuration = DioramaConfiguration(
                    region: key.region, shape: key.shape, physicalSize: key.physicalSize, style: key.style
                )
                configuration.usesGeographicAnchor = usesGeographicAnchor
                await store.reload(configuration: configuration)
            }
            guard store.loadGeneration == generation + 1, revision == store.navigationRevision, !Task.isCancelled else { return }
            if let latestContent { store.applyContent(latestContent()) } else { store.applyContent(content) }
            afterLoad()
        }
    }

    /// A tap landed on an entity; walk up to structured marker identity and toggle selection.
    static func handleTap(
        on entity: Entity,
        selection: DioramaSelection?,
        store: DioramaStore
    ) {
        guard let selection else { return }
        var current: Entity? = entity
        while let candidate = current {
            if let identity = candidate.components[DioramaMarkerIdentity.self] {
                selection.toggle(identity)
                applySelection(selection, store: store)
                return
            }
            current = candidate.parent
        }
    }

    /// Reflects the current selection onto every rendered part of each marker feature.
    static func applySelection(_ selection: DioramaSelection?, store: DioramaStore, spatial: Bool? = nil) {
        guard let root = store.dioramaEntity as? DioramaEntity else { return }
        root.selection = selection
        if let spatial { root.overlayRenderer.spatialHitTesting = spatial }
        root.overlayRenderer.updateSelection()
        for marker in root.markerEntities.values {
            let selected = marker.components[DioramaMarkerIdentity.self].map {
                selection?.isSelected($0) ?? false
            } ?? false
            marker.setSelected(selected)
        }
    }
}
