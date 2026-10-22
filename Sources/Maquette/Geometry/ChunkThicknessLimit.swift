import simd

/// Shared proportion: raster padding below its lowest ground, or photorealistic local thickness.
enum ChunkThicknessLimit {
    static func maximum(for boundary: DioramaBoundary) -> Float {
        max(boundary.extent.x, boundary.extent.y) * 0.1
    }
}
