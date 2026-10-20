import Foundation
import SwiftUI
import simd

/// A scene-space orbit pose. Heading is clockwise from north; pitch is measured from overhead.
struct DioramaCameraPose: Sendable, Equatable {
    var heading: Double
    var pitch: Double
    var distance: Float
    var target: SIMD3<Float>

    var right: SIMD3<Float> {
        let h = heading * .pi / 180
        return SIMD3(Float(cos(h)), 0, Float(sin(h)))
    }

    /// Analytic basis preserves the requested heading even exactly overhead.
    var up: SIMD3<Float> {
        let h = heading * .pi / 180, p = pitch * .pi / 180
        return SIMD3(Float(sin(h) * cos(p)), Float(sin(p)), Float(-cos(h) * cos(p)))
    }

    var forward: SIMD3<Float> {
        let h = heading * .pi / 180, p = pitch * .pi / 180
        return SIMD3(Float(sin(h) * sin(p)), Float(-cos(p)), Float(-cos(h) * sin(p)))
    }

    var position: SIMD3<Float> { target - forward * distance }
}

enum DioramaCameraGeometry {
    static func normalizedHeading(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    /// Fits the complete axis-aligned bounds, including relief, into the padded perspective frame.
    /// The focus moves in the camera's right/up plane to account for asymmetric padding.
    static func fit(points: [SIMD3<Float>], pose: DioramaCameraPose, viewport: CGSize,
                    padding: EdgeInsets, limits: DioramaCameraLimits,
                    verticalFieldOfView: Float = .pi / 3) -> DioramaCameraPose? {
        guard valid(pose), valid(viewport, verticalFieldOfView), !points.isEmpty,
              points.allSatisfy(finite),
              [padding.top, padding.leading, padding.bottom, padding.trailing].allSatisfy({ $0.isFinite && $0 >= 0 }),
              padding.leading + padding.trailing < viewport.width,
              padding.top + padding.bottom < viewport.height else { return nil }

        var lower = points[0], upper = points[0]
        for point in points { lower = simd_min(lower, point); upper = simd_max(upper, point) }
        let center = lower / 2 + upper / 2
        var result = pose
        result.heading = normalizedHeading(pose.heading)
        result.pitch = min(max(pose.pitch, limits.pitchDegrees.lowerBound), limits.pitchDegrees.upperBound)
        result.target = center
        let corners = [lower.x, upper.x].flatMap { x in
            [lower.y, upper.y].flatMap { y in [lower.z, upper.z].map { SIMD3(x, y, $0) } }
        }
        let basisRight = result.right, basisUp = result.up, basisForward = result.forward
        let local = corners.map { point -> (x: Double, y: Double, z: Double) in
            let v = point - center
            return (Double(simd_dot(v, basisRight)), Double(simd_dot(v, basisUp)), Double(simd_dot(v, basisForward)))
        }
        let tangent = tan(Double(verticalFieldOfView) / 2)
        let aspect = Double(viewport.width / viewport.height)
        let left = (2 * Double(padding.leading / viewport.width) - 1) * tangent * aspect
        let right = (1 - 2 * Double(padding.trailing / viewport.width)) * tangent * aspect
        let bottom = (2 * Double(padding.bottom / viewport.height) - 1) * tangent
        let top = (1 - 2 * Double(padding.top / viewport.height)) * tangent

        // At a given distance each side plane constrains a focus offset interval. Increasing
        // distance expands both intervals, so feasibility is monotonic and bisection is exact.
        func offsets(_ distance: Double) -> (Double, Double)? {
            var minX = -Double.infinity, maxX = Double.infinity
            var minY = -Double.infinity, maxY = Double.infinity
            for point in local {
                let depth = distance + point.z
                guard depth > 0 else { return nil }
                minX = max(minX, point.x - right * depth)
                maxX = min(maxX, point.x - left * depth)
                minY = max(minY, point.y - top * depth)
                maxY = min(maxY, point.y - bottom * depth)
            }
            guard minX <= maxX, minY <= maxY else { return nil }
            return ((minX + maxX) / 2, (minY + maxY) / 2)
        }

        var low = Double(limits.distance.lowerBound)
        let ceiling = Double(limits.distance.upperBound)
        if offsets(low) == nil {
            // Bracket near the actual solution before bisection. A legal ceiling may be
            // Float.greatestFiniteMagnitude; bisecting that entire range loses scene scale.
            var high = min(ceiling, max(low * 2, 0.000001))
            while offsets(high) == nil {
                guard high < ceiling else { return nil }
                low = high
                high = min(ceiling, high * 2)
            }
            for _ in 0..<64 {
                let middle = (low + high) / 2
                if offsets(middle) != nil { high = middle } else { low = middle }
            }
            low = high
        }
        // Leave room for scene Float conversion at a tight side-plane intersection.
        result.distance = Float(min(Double(limits.distance.upperBound), low + max(0.000001, low * 0.00001)))
        guard let (x, y) = offsets(Double(result.distance)) else { return nil }
        result.target = center + basisRight * Float(x) + basisUp * Float(y)
        guard valid(result) else { return nil }
        for point in corners {
            guard let pixel = projectedPoint(point, pose: result, viewport: viewport, verticalFieldOfView: verticalFieldOfView),
                  pixel.x >= padding.leading - 0.001, pixel.x <= viewport.width - padding.trailing + 0.001,
                  pixel.y >= padding.top - 0.001, pixel.y <= viewport.height - padding.bottom + 0.001 else { return nil }
        }
        return result
    }

    static func projectedPoint(_ point: SIMD3<Float>, pose: DioramaCameraPose, viewport: CGSize,
                               verticalFieldOfView: Float = .pi / 3) -> CGPoint? {
        guard finite(point), valid(pose), valid(viewport, verticalFieldOfView) else { return nil }
        let relative = point - pose.target
        let depth = Double(pose.distance) + Double(simd_dot(relative, pose.forward))
        guard depth > 0, depth.isFinite else { return nil }
        let tangent = tan(Double(verticalFieldOfView) / 2)
        let x = Double(simd_dot(relative, pose.right)) / (depth * tangent * Double(viewport.width / viewport.height))
        let y = Double(simd_dot(relative, pose.up)) / (depth * tangent)
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: (x + 1) * Double(viewport.width) / 2, y: (1 - y) * Double(viewport.height) / 2)
    }

    /// Applies smoothstep easing to elapsed normalized time, with the shortest heading arc.
    static func interpolate(from: DioramaCameraPose, to: DioramaCameraPose, progress: Double) -> DioramaCameraPose {
        guard progress > 0 else { return from }
        guard progress < 1 else { return to }
        let t = progress * progress * (3 - 2 * progress)
        var delta = normalizedHeading(to.heading - from.heading)
        if delta > 180 { delta -= 360 }
        return DioramaCameraPose(
            heading: normalizedHeading(from.heading + delta * t),
            pitch: from.pitch + (to.pitch - from.pitch) * t,
            distance: from.distance + (to.distance - from.distance) * Float(t),
            target: from.target + (to.target - from.target) * Float(t))
    }

    private static func finite(_ point: SIMD3<Float>) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
    }

    private static func valid(_ pose: DioramaCameraPose) -> Bool {
        pose.heading.isFinite && pose.pitch.isFinite && (0...90).contains(pose.pitch)
            && pose.distance.isFinite && pose.distance > 0 && finite(pose.target)
    }

    private static func valid(_ viewport: CGSize, _ fieldOfView: Float) -> Bool {
        viewport.width.isFinite && viewport.height.isFinite && viewport.width > 0 && viewport.height > 0
            && fieldOfView.isFinite && fieldOfView > 0 && fieldOfView < .pi
    }
}


extension DioramaCameraGeometry {
    /// Whole-edge containment matters for concave outlines: inside endpoints alone are insufficient.
    static func contains(_ points: [SIMD2<Float>], boundary: [SIMD2<Float>], closed: Bool) -> Bool {
        guard !points.isEmpty, boundary.count >= 3 else { return false }
        let ring = boundary.map { OverlayVertex(point: SIMD2<Double>($0)) }
        let epsilon = OverlayBounds(ring.map(\.point)).epsilon
        var path = points.map { OverlayVertex(point: SIMD2<Double>($0)) }
        guard path.allSatisfy(\.isFinite), path.allSatisfy({ OverlayMath.locate($0.point, in: ring, epsilon: epsilon) != .outside }) else { return false }
        if closed, path.first?.point != path.last?.point { path.append(path[0]) }
        if path.count == 1 { return true }
        var length = 0.0
        for i in 1..<path.count { length += simd_distance(path[i - 1].point, path[i].point) }
        guard let runs = try? OverlayLineClipper.clip(path, boundary: ring) else { return false }
        var contained = 0.0
        for run in runs { for i in 1..<run.count { contained += run[i].distance - run[i - 1].distance } }
        return abs(length - contained) <= max(1e-8, length * 1e-7)
    }
}
