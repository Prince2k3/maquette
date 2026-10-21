import simd

/// One coalesced target while the preceding complete ground frame is being prepared.
struct PendingGroundInput {
    var pan: SIMD2<Float>?
    var scale: Float?

    func zoomTarget(from currentScale: Float, by factor: Float) -> Float {
        (scale ?? currentScale) * factor
    }

    /// A queued drag names the same geographic ground after an accepted (possibly clamped) zoom.
    func pan(from previousScale: Float, to acceptedScale: Float) -> SIMD2<Float>? {
        pan.map { $0 * (previousScale / acceptedScale) }
    }
}
