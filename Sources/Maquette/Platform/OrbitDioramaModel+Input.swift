#if os(iOS) || os(macOS)
import SwiftUI

extension OrbitDioramaModel {
    var hasInputOrbit: Bool {
        store.loadingState == .loaded && !arPlacementActive && !transition.isShowingGlobe
            && !isInteractionLocked && !navigation.isApplyingRequest
    }

    func canZoom(_ target: DioramaZoomTarget) -> Bool {
        guard !isInteractionLocked, !navigation.isApplyingRequest, store.loadingState == .loaded else { return false }
        switch target {
        case .ground: return enabledGestures.contains(.zoom) && (store.canZoomGround || transition.isShowingGlobe)
        case .camera: return enabledGestures.contains(.cameraZoom) && hasInputOrbit
        }
    }

    var inputControlNavigation: DioramaControlNavigation {
        let camera = resolvedCamera
        let ground = canZoom(.ground)
        let range = store.groundScaleLimits
        let cameraZoom = canZoom(.camera)
        return .init(
            canGroundZoomIn: ground && (transition.isShowingGlobe || store.groundScale > range.lowerBound * 1.0001),
            canGroundZoomOut: ground && (transition.isShowingGlobe || store.groundScale < range.upperBound * 0.9999 || (globeStyle != nil && store.globe != nil)),
            canCameraZoomIn: cameraZoom && camera.distance > cameraLimits.distance.lowerBound * 1.0001,
            canCameraZoomOut: cameraZoom && camera.distance < cameraLimits.distance.upperBound * 0.9999,
            groundScale: store.groundScale, cameraDistance: camera.distance,
            pitch: arPlacementActive || transition.isShowingGlobe ? nil : camera.pitch,
            pitchRange: cameraLimits.pitchDegrees,
            canPitch: hasInputOrbit && enabledGestures.allowsPitch,
            canFit: hasInputOrbit && enabledGestures.contains(.cameraZoom),
            canTogglePerspective: hasInputOrbit && enabledGestures.allowsPitch && (camera.pitch.degrees < 0.001 ? cameraLimits.pitchDegrees.upperBound > 0 : cameraLimits.pitchDegrees.contains(0)),
            zoom: { [weak self] target, steps in self?.performInput(.zoom(target, steps: steps)) },
            setPitch: { [weak self] degrees in self?.setPitchFromInput(degrees) },
            togglePerspective: { [weak self] in
                guard let self else { return }
                self.performInput(self.resolvedCamera.pitch.degrees < 0.001 ? .oblique : .overhead)
            }
        )
    }

    private func setPitchFromInput(_ degrees: Double) {
        guard hasInputOrbit, enabledGestures.allowsPitch, degrees.isFinite else { return }
        var camera = resolvedCamera
        camera.pitch = .degrees(min(max(degrees, cameraLimits.pitchDegrees.lowerBound), cameraLimits.pitchDegrees.upperBound))
        _ = DioramaCameraProxy(host: cameraHost).setCamera(camera, transition: .immediate)
    }

    @discardableResult
    func performInput(_ action: DioramaInputAction) -> Bool {
        switch action {
        case .pan(let horizontal, let vertical):
            guard horizontal.isFinite, vertical.isFinite,
                  enabledGestures.contains(.pan), canPanTerrain || transition.isShowingGlobe,
                  !isInteractionLocked, !navigation.isApplyingRequest else { return false }
            primaryDrag(dx: horizontal, dy: vertical)
            endInteraction(.drag)
        case .orbit(let heading, let pitch):
            guard hasInputOrbit, heading.isFinite, pitch.isFinite,
                  (heading != 0 && enabledGestures.allowsHeading) || (pitch != 0 && enabledGestures.allowsPitch) else { return false }
            orbitInput(headingDegrees: heading, pitchDegrees: pitch)
            endInteraction(.drag)
        case .zoom(let target, let steps):
            guard steps.isFinite, steps != 0,
                  zoomInput(Float(steps * 10), target: target) else { return false }
            endInteraction(.zoom)
        case .north:
            guard controlState.canFaceNorth else { return false }
            faceNorthFromControls()
        case .overhead, .oblique:
            guard hasInputOrbit, enabledGestures.allowsPitch else { return false }
            let pitch = action == .overhead ? 0.0 : min(max(45, cameraLimits.pitchDegrees.lowerBound), cameraLimits.pitchDegrees.upperBound)
            guard cameraLimits.pitchDegrees.contains(pitch) else { return false }
            var camera = resolvedCamera
            camera.pitch = .degrees(pitch)
            _ = DioramaCameraProxy(host: cameraHost).setCamera(camera, transition: .easeInOut(duration: 0.35))
        case .fit:
            guard inputControlNavigation.canFit else { return false }
            _ = DioramaCameraProxy(host: cameraHost).fit(.chunk, transition: .easeInOut(duration: 0.35))
        case .reset:
            guard controlState.canReset else { return false }
            resetFromControls()
        }
        return true
    }

    func keyboardInput(key: KeyEquivalent, modifiers: EventModifiers) -> Bool {
        guard inputFocused,
              let mapping = inputConfiguration.keyboardShortcuts.first(where: { $0.key == key && $0.modifiers == modifiers.intersection([.shift, .option, .control, .command]) }) else { return false }
        return performInput(mapping.action)
    }
}
#endif
