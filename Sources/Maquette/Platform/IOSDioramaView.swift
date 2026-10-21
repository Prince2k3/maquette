#if os(iOS)
import SwiftUI

/// iOS presentation of the diorama: the shared orbit scene driven by touch.
///
/// One finger pans, two-finger twist changes heading, two-finger vertical drag changes pitch,
/// and pinch zooms the ground. The legacy preset keeps two-finger drag orbiting.
/// `DragGesture` cannot express that split because it reports a translation without saying how
/// many fingers produced it, so everything is driven from a single `SpatialEventGesture` feeding
/// raw touch locations through ``MultitouchDragTracker``. Handling all three intents in one
/// gesture also avoids arbitration between competing recognizers.
struct IOSDioramaView: View {
    let inputs: DioramaViewInputs

    var body: some View {
        OrbitDioramaView(inputs: inputs) { model in
            IOSDioramaGestures(model: model)
        }
    }
}

/// Translates raw multitouch into the shared model's intents.
private struct IOSDioramaGestures: ViewModifier {
    let model: OrbitDioramaModel
    @State private var dragTracker = MultitouchDragTracker()

    /// Converts the change in touch spread, in points, into a zoom delta.
    private static let pinchZoomScale: Float = 0.3

    func body(content: Content) -> some View {
        // One gesture handles everything, so pan, orbit, and zoom never contend for the same
        // touches: one finger slides the ground, two orbit the camera and pinch to zoom.
        content.gesture(
            SpatialEventGesture(coordinateSpace: .local)
                .onChanged { events in
                    let active = events.filter { $0.phase == .active }
                    // The touches' own timestamps, not the delivery's: the point of carrying them is
                    // that when a touch was sampled and when its frame runs are different questions.
                    let update = dragTracker.update(
                        touches: Dictionary(active.map { ($0.id, $0.location) }, uniquingKeysWith: { _, latest in latest }),
                        at: active.map(\.timestamp).max()
                    )
                    guard let update else { return }
                    apply(update)
                }
                .onEnded { _ in
                    dragTracker.reset()
                    model.endInteraction()
                }
        )
        .onAppear { dragTracker.thresholds = model.inputConfiguration.preset == .legacyOrbit ? .none : .standard }
        .onChange(of: model.inputConfiguration.preset) { _, preset in
            dragTracker = MultitouchDragTracker(thresholds: preset == .legacyOrbit ? .none : .standard)
            model.endInteraction()
        }
    }

    /// Routes a multitouch update to the model: one finger is the primary drag, two are orbit+zoom.
    private func apply(_ update: MultitouchDragTracker.Update) {
        let dx = Float(update.translation.width)
        let dy = Float(update.translation.height)

        if update.touchCount == 1 {
            model.primaryDrag(dx: dx, dy: dy, at: update.time)
            return
        }

        if model.inputConfiguration.preset == .legacyOrbit {
            model.secondaryDrag(dx: dx, dy: dy)
            model.zoomInput(Float(update.spreadChange) * Self.pinchZoomScale)
        } else {
            model.orbitInput(
                headingDegrees: -Double(update.rotationChangeRadians) * 180 / .pi * Double(model.inputConfiguration.resolved.orbitSensitivity),
                pitchDegrees: Double(dy * model.cameraController.rotationSensitivity * model.inputConfiguration.resolved.orbitSensitivity) * 180 / .pi
            )
            model.zoomInput(Float(update.log2ScaleRatio) * 25)
        }
    }
}
#endif
