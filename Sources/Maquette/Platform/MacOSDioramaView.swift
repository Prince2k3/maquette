#if os(macOS)
import AppKit
import SwiftUI

/// macOS presentation of the diorama: the shared orbit scene driven by pointer and trackpad.
///
/// A pointer has no second finger, so the multitouch split used on iOS becomes a modifier here:
/// option-drag orbits, matching the two-finger gesture, and a plain drag slides the ground the
/// way a map does. Zoom comes from trackpad pinch and the scroll wheel.
struct MacOSDioramaView: View {
    let inputs: DioramaViewInputs

    var body: some View {
        OrbitDioramaView(inputs: inputs) { model in
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
            .highPriorityGestureIf(model.enabledGestures.allowsHeading || model.enabledGestures.allowsPitch,
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
                        model.endInteraction(.drag)
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
                        model.endInteraction(.drag)
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
                        model.endInteraction(.zoom)
                    }
            )
            // The scroll wheel and two-finger scroll. There is no pure-SwiftUI hook for scroll
            // events over a non-scrolling view — `onScrollGeometryChange` only reports an enclosing
            // ScrollView's geometry, and there is none — so a minimal AppKit reader sits behind the
            // scene and forwards the deltas.
            .background(
                ScrollWheelReader(
                    isFocused: { model.inputFocused },
                    configuration: { model.inputConfiguration },
                    excludesPoint: { point in
                        let insets = model.cameraControlInsets
                        let interior = CGRect(x: insets.leading, y: insets.top,
                            width: max(0, model.viewSize.width - insets.leading - insets.trailing),
                            height: max(0, model.viewSize.height - insets.top - insets.bottom))
                        return !interior.contains(point) || model.store.annotationRegistry.orderedRecords.contains {
                            $0.visible && ($0.frame?.contains(point) ?? false)
                        }
                    },
                    onScroll: { delta, target in
                        model.zoomInput(delta * Self.scrollZoomScale, isWheel: true, target: target)
                    }
                )
            )
    }

    /// How much zoom a unit of pinch ratio is worth, calibrated so a full trackpad pinch covers
    /// about the same share of the ground-zoom ladder as a full-width pinch does on iOS.
    ///
    /// A full trackpad pinch spans a magnification ratio of roughly ¼–4, so |log2| ≈ 2 either way;
    /// at 25 that is a delta of ~50, the same ~4 octaves per gesture iOS and visionOS deliver, and
    /// the globe is two or three pinches out from a freshly loaded chunk. The previous 12 was half
    /// that rate — the same handoff at twice the pinch count, which is how "the transition doesn't
    /// work on macOS" gets reported by someone who gave up before reaching it.
    private static let magnifyZoomScale: Float = 25

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

/// Pure wheel policy, shared by the native reader and ownership tests.
struct MacOSInputOwnership {
    static func eligible(isKeyWindow: Bool, isFocused: Bool, insideVisibleRect: Bool,
                         excluded: Bool, isMomentum: Bool, ownsSequence: Bool) -> Bool {
        isKeyWindow && isFocused && insideVisibleRect && !excluded && (!isMomentum || ownsSequence)
    }

    static func normalizedDelta(_ delta: CGFloat, precise: Bool, inverted: Bool) -> Float {
        Float(delta) * (precise ? 1 : 10) * (inverted ? -1 : 1)
    }

    static func target(configuration: DioramaInputConfiguration, modifiers: EventModifiers) -> DioramaZoomTarget {
        let alternate = configuration.alternateWheelModifiers
        guard !alternate.isEmpty, modifiers.contains(alternate) else { return configuration.wheelZoomTarget }
        return configuration.wheelZoomTarget == .ground ? .camera : .ground
    }
}

extension NSEvent.ModifierFlags {
    var dioramaEventModifiers: EventModifiers {
        var result: EventModifiers = []
        if contains(.shift) { result.insert(.shift) }
        if contains(.control) { result.insert(.control) }
        if contains(.option) { result.insert(.option) }
        if contains(.command) { result.insert(.command) }
        if contains(.capsLock) { result.insert(.capsLock) }
        return result
    }
}

/// A local monitor is needed on macOS 15 because a background NSView does not receive
/// RealityView's scroll events. Each host owns its monitor and consumes only accepted zooms.
/// Native trackpad rotation is not mapped by this adapter; option-drag supplies independent
/// heading and pitch on the macOS 15 deployment floor.
private struct ScrollWheelReader: NSViewRepresentable {
    let isFocused: () -> Bool
    let configuration: () -> DioramaInputConfiguration
    let excludesPoint: (CGPoint) -> Bool
    let onScroll: (Float, DioramaZoomTarget) -> Bool

    func makeNSView(context: Context) -> ScrollWheelView {
        let view = ScrollWheelView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: ScrollWheelView, context: Context) {
        nsView.isFocused = isFocused
        nsView.configuration = configuration
        nsView.excludesPoint = excludesPoint
        nsView.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: ScrollWheelView, coordinator: ()) {
        nsView.removeMonitor()
    }

    final class ScrollWheelView: NSView {
        override var isFlipped: Bool { true }
        var isFocused: (() -> Bool)?
        var configuration: (() -> DioramaInputConfiguration)?
        var excludesPoint: ((CGPoint) -> Bool)?
        var onScroll: ((Float, DioramaZoomTarget) -> Bool)?
        private var monitor: Any?
        private var ownsSequence = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self else { return event }
                    return self.handle(event)
                }
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            ownsSequence = false
        }

        private func isControl(at point: CGPoint, in window: NSWindow) -> Bool {
            if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor { return true }
            guard let content = window.contentView else { return false }
            var hit = content.hitTest(content.convert(point, from: nil))
            while let view = hit {
                if view is NSControl || view is NSTextView { return true }
                // An enclosing ScrollView must still allow navigation over the scene. A nested
                // scrolling annotation owns its wheel, and its frame is also excluded above.
                if view is NSScrollView, !isDescendant(of: view) { return true }
                hit = view.superview
            }
            return false
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window else { return event }
            if event.phase.contains(.began) || event.phase.contains(.mayBegin) { ownsSequence = false }
            let location = convert(event.locationInWindow, from: nil)
            let momentum = !event.momentumPhase.isEmpty
            let excluded = (excludesPoint?(location) ?? false) || isControl(at: event.locationInWindow, in: window)
            guard MacOSInputOwnership.eligible(isKeyWindow: window.isKeyWindow,
                isFocused: isFocused?() ?? false, insideVisibleRect: visibleRect.intersection(bounds).contains(location),
                excluded: excluded, isMomentum: momentum, ownsSequence: ownsSequence) else {
                ownsSequence = false
                return event
            }
            // A tail is suppressed only after this reader accepted its direct input sequence.
            if momentum {
                if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { ownsSequence = false }
                return nil
            }
            if event.phase.contains(.cancelled) { ownsSequence = false; return event }
            let delta = MacOSInputOwnership.normalizedDelta(event.scrollingDeltaY,
                precise: event.hasPreciseScrollingDeltas, inverted: event.isDirectionInvertedFromDevice)
            guard delta.isFinite, delta != 0 else { return event }
            let target = MacOSInputOwnership.target(configuration: configuration?() ?? .map,
                modifiers: event.modifierFlags.dioramaEventModifiers)
            guard onScroll?(delta, target) == true else { ownsSequence = false; return event }
            // Phase-less mouse wheels have no following momentum sequence.
            ownsSequence = !event.phase.isEmpty
            return nil
        }
    }
}
#endif
