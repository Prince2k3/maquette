#if os(macOS)
import AppKit
import SwiftUI

/// macOS presentation of the diorama: the shared orbit scene driven by pointer and trackpad.
///
/// A pointer has no second finger, so the multitouch split used on iOS becomes a modifier here:
/// option-drag orbits, matching the two-finger gesture, and a plain drag slides the ground the
/// way a map does. Zoom comes from trackpad pinch and the scroll wheel.
struct MacOSDioramaView: View {
    let configuration: DioramaConfiguration
    let content: DioramaContentGroup?

    var body: some View {
        OrbitDioramaView(configuration: configuration, content: content) { model in
            MacOSDioramaGestures(model: model)
        }
    }
}

/// Translates pointer and trackpad input into the shared model's intents.
private struct MacOSDioramaGestures: ViewModifier {
    let model: OrbitDioramaModel
    @State private var lastDragTranslation: CGSize = .zero
    @State private var lastMagnification: CGFloat?

    func body(content: Content) -> some View {
        content
            .highPriorityGestureIf(model.enabledGestures.contains(.rotate),
                DragGesture(minimumDistance: 1)
                    .modifiers(.option)
                    .onChanged { value in
                        // Consumed first, then refused: the baseline has to stay current or the
                        // whole of an animation's worth of drag lands as one jump when it finishes.
                        let delta = consumeDragDelta(value.translation)
                        model.secondaryDrag(dx: delta.x, dy: delta.y)
                    }
                    .onEnded { _ in
                        lastDragTranslation = .zero
                    }
            )
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let delta = consumeDragDelta(value.translation)
                        model.primaryDrag(dx: delta.x, dy: delta.y)
                    }
                    .onEnded { _ in
                        lastDragTranslation = .zero
                    }
            )
            // Trackpad pinch. Read as per-change ratios rather than absolute magnification, so the
            // gesture's meaning does not depend on where it started; log2 of the ratio is octaves,
            // the same currency the ground-zoom rate is calibrated in.
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let previous = lastMagnification ?? 1
                        lastMagnification = value.magnification
                        let ratio = Float(value.magnification / previous)
                        guard ratio > 0 else { return }
                        model.zoomInput(log2(ratio) * Self.magnifyZoomScale)
                    }
                    .onEnded { _ in
                        lastMagnification = nil
                    }
            )
            // The scroll wheel and two-finger scroll. There is no pure-SwiftUI hook for scroll
            // events over a non-scrolling view — `onScrollGeometryChange` only reports an enclosing
            // ScrollView's geometry, and there is none — so a minimal AppKit reader sits behind the
            // scene and forwards the deltas.
            .background(
                ScrollWheelReader { deltaY in
                    model.zoomInput(Float(deltaY) * Self.scrollZoomScale)
                }
            )
    }

    /// How much zoom a unit of pinch ratio is worth, calibrated so a full trackpad pinch covers
    /// about the same share of the ground-zoom ladder as a full-width pinch does on iOS.
    private static let magnifyZoomScale: Float = 12

    /// How much zoom a point of scroll delta is worth. The previous scroll path used 0.1 per point;
    /// kept, so anyone used to the old feel gets the same rate now that the events actually arrive.
    private static let scrollZoomScale: Float = 0.1

    /// Returns the movement since the last drag callback and stores the new position.
    private func consumeDragDelta(_ translation: CGSize) -> SIMD2<Float> {
        let delta = SIMD2(
            Float(translation.width - lastDragTranslation.width),
            Float(translation.height - lastDragTranslation.height)
        )
        lastDragTranslation = translation
        return delta
    }
}

/// Forwards scroll-wheel events over the diorama to SwiftUI.
///
/// A background view cannot simply override `scrollWheel(with:)`: AppKit delivers scroll events
/// to the *hit-tested* view under the cursor — the RealityView — and then up its responder chain,
/// so an occluded sibling never hears them. A local event monitor sees every scroll event in the
/// window instead; this one acts only when the cursor is inside the reader's own bounds, so two
/// dioramas in one window each hear their own wheel.
private struct ScrollWheelReader: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollWheelView {
        let view = ScrollWheelView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollWheelView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class ScrollWheelView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    self?.handle(event)
                    // Passed on rather than swallowed: nothing else in the hierarchy zooms on
                    // scroll, and swallowing would break any scrollable chrome the app adds.
                    return event
                }
            }
        }

        // No deinit: a nonisolated deinit may not touch the non-Sendable monitor handle, so its
        // removal rides window membership instead — `viewDidMoveToWindow` fires with a nil window
        // when the view leaves the hierarchy, which precedes deallocation for a hosted view.

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handle(_ event: NSEvent) {
            guard let window, event.window === window else { return }
            let location = convert(event.locationInWindow, from: nil)
            guard bounds.contains(location) else { return }
            // Precise deltas (trackpads) arrive in points and already feel right; line-based
            // wheels report small line counts, so they are stepped up to a comparable rate.
            let delta = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY
                : event.scrollingDeltaY * 10
            guard delta != 0 else { return }
            onScroll?(delta)
        }
    }
}
#endif
