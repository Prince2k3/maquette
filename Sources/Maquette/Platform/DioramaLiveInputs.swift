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

        let sameSubstrate = key.region.radius == current.radiusMeters
            && key.shape == current.shape
            && key.physicalSize == current.physicalSize
            && currentStyle == targetStyle
        let sameCenter = Coordinate(current.center) == key.region.center

        if sameSubstrate && sameCenter {
            if visibilityChanged, let targetVisibility {
                store.configuration.buildings?.isVisible = targetVisibility
                store.setBuildingsVisible(targetVisibility)
            }
            return
        }
        Task {
            if sameSubstrate {
                await store.relocate(to: key.region.center)
            } else {
                await store.reload(configuration: DioramaConfiguration(
                    region: key.region, shape: key.shape, physicalSize: key.physicalSize, style: key.style
                ))
            }
            store.applyContent(content)
            afterLoad()
        }
    }

    /// A tap landed on an entity; walk up for a marker and toggle the selection binding.
    static func handleTap(
        on entity: Entity,
        selection: Binding<DioramaAnnotation.ID?>?,
        store: DioramaStore
    ) {
        guard let selection else { return }
        var current: Entity? = entity
        while let candidate = current {
            if candidate.name.hasPrefix("Marker_") {
                let id = String(candidate.name.dropFirst("Marker_".count))
                let newValue = selection.wrappedValue == id ? nil : id
                selection.wrappedValue = newValue
                applySelection(newValue, store: store)
                return
            }
            current = candidate.parent
        }
    }

    /// Reflects the selected identity onto the marker entities.
    static func applySelection(_ id: DioramaAnnotation.ID?, store: DioramaStore) {
        guard let root = store.dioramaEntity as? DioramaEntity else { return }
        for (key, marker) in root.markerEntities {
            // A multi-geometry's parts are suffixed `id#index`; selecting the feature selects them all.
            let selected = id.map { key == $0 || key.hasPrefix("\($0)#") } ?? false
            marker.setSelected(selected)
        }
    }
}
