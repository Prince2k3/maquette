import CoreGraphics
import Foundation
import RealityKit
import simd

struct OverlayRay {
    var origin: SIMD3<Float>
    var direction: SIMD3<Float>
}

enum OverlayHitTesting {
    static func distance(positions: [SIMD3<Float>], indices: [UInt32], ray: OverlayRay) -> Float? {
        let origin = SIMD3<Double>(ray.origin), direction = SIMD3<Double>(simd_normalize(ray.direction))
        var closest = Double.infinity
        for i in stride(from: 0, to: indices.count, by: 3) {
            let a = SIMD3<Double>(positions[Int(indices[i])]), b = SIMD3<Double>(positions[Int(indices[i + 1])]), c = SIMD3<Double>(positions[Int(indices[i + 2])])
            let edge = b - a, other = c - a, h = simd_cross(direction, other), determinant = simd_dot(edge, h)
            guard abs(determinant) > 1e-15 else { continue }
            let offset = origin - a, u = simd_dot(offset, h) / determinant
            guard u >= -1e-8, u <= 1 + 1e-8 else { continue }
            let q = simd_cross(offset, edge), v = simd_dot(direction, q) / determinant
            guard v >= -1e-8, u + v <= 1 + 1e-8 else { continue }
            let t = simd_dot(other, q) / determinant
            if t >= 0 { closest = min(closest, t) }
        }
        return closest.isFinite ? Float(closest) : nil
    }
    static func segment(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> (distance: Double, t: Float) {
        let p = SIMD2(Double(point.x), Double(point.y)), start = SIMD2(Double(a.x), Double(a.y)), end = SIMD2(Double(b.x), Double(b.y))
        let delta = end - start, length = simd_length_squared(delta)
        let t = length > 0 ? max(0, min(1, simd_dot(p - start, delta) / length)) : 0
        return (simd_distance(p, start + delta * t), Float(t))
    }
}

extension DioramaOverlayRenderer {
    /// Projection is in logical view points, so the line tolerance is independent of display scale.
    func hitTest(at point: CGPoint, project: (SIMD3<Float>) -> CGPoint?, ray: OverlayRay,
                 lineTolerance: Double = 8) -> DioramaMarkerIdentity? {
        guard let root, root.isEnabled, root.terrain?.isPanPresentationDeferred != true,
              let selection = root.selection else { return nil }
        var occlusion = Float.infinity
        for buffers in [root.terrain?.surfaceBuffers, root.terrain?.wallBuffers, root.terrain?.bottomBuffers].compactMap({ $0 }) {
            if let depth = OverlayHitTesting.distance(positions: buffers.positions, indices: buffers.indices, ray: ray) { occlusion = min(occlusion, depth) }
        }
        var candidates: [(depth: Float, order: Int, identity: DioramaMarkerIdentity)] = []
        let direction = simd_normalize(ray.direction)
        for marker in root.markerEntities.values where marker.isEnabled {
            guard let identity = marker.components[DioramaMarkerIdentity.self], selection.tag(for: identity) != nil else { continue }
            let head = marker.children.first { $0.name == "MarkerHead" }
            let p = head?.convert(position: .zero, to: root) ?? marker.position
            guard let location = project(p), hypot(location.x - point.x, location.y - point.y) <= 22 else { continue }
            let depth = simd_dot(p - ray.origin, direction)
            if depth >= 0, depth <= occlusion + 0.0001 { candidates.append((depth, Int.max, identity)) }
        }
        for record in records.values where record.entity.isEnabled && record.key == record.appliedKey {
            guard let identity = record.entity.components[DioramaMarkerIdentity.self], selection.tag(for: identity) != nil else { continue }
            var depth = Float.infinity
            for part in record.layers.values {
                let mesh = part.mesh
                if let hit = OverlayHitTesting.distance(positions: mesh.positions, indices: mesh.indices, ray: ray) { depth = min(depth, hit) }
                if record.input.shape.isLine {
                    for i in stride(from: 0, to: mesh.indices.count, by: 3) {
                        let vertices = (0..<3).map { mesh.positions[Int(mesh.indices[i + $0])] }
                        guard let a = project(vertices[0]), let b = project(vertices[1]), let c = project(vertices[2]) else { continue }
                        for (j, pair) in [(a, b), (b, c), (c, a)].enumerated() {
                            let hit = OverlayHitTesting.segment(point, pair.0, pair.1)
                            if hit.distance <= lineTolerance {
                                let p = vertices[j] + (vertices[(j + 1) % 3] - vertices[j]) * hit.t
                                let t = simd_dot(p - ray.origin, direction)
                                if t >= 0 { depth = min(depth, t) }
                            }
                        }
                    }
                }
            }
            if depth.isFinite, depth <= occlusion + 0.0001 { candidates.append((depth, record.order, identity)) }
        }
        return candidates.sorted {
            if abs($0.depth - $1.depth) > 1e-5 { return $0.depth < $1.depth }
            if $0.order != $1.order { return $0.order > $1.order }
            return $0.identity.annotationID < $1.identity.annotationID
        }.first?.identity
    }

    func configureSpatialTarget(_ record: Record, identity: DioramaMarkerIdentity) {
        guard spatialHitTesting, record.entity.isEnabled, record.key == record.appliedKey,
              root?.selection?.tag(for: identity) != nil else {
            record.collisionTask?.cancel(); record.collisionTask = nil; record.collisionKey = nil; record.collisionRequest = UUID()
            record.entity.components.remove(CollisionComponent.self); record.entity.components.remove(InputTargetComponent.self)
            return
        }
        guard record.collisionKey != record.appliedKey, record.collisionTask == nil else { return }
        let key = record.appliedKey, input = record.input, proxy = currentProxy
        let meshes = record.layers.values.map(\.mesh)
        let request = UUID(); record.collisionRequest = request
        record.collisionTask = Task { [weak self, weak record] in
            do {
                var geometry = meshes
                if input.shape.isLine, let proxy, let key {
                    var style = input.annotation.style
                    style.strokeStyle = .init(width: .physicalMeters(key.context.physicalSize * 0.012), lineCap: .round, lineJoin: .round)
                    let hitStyle = style
                    let worker = Task.detached {
                        let surface = try await self?.surfaceForCollision()
                        return try DioramaOverlayGeometryBuilder.build(shape: input.shape, style: hitStyle, proxy: proxy,
                            surface: surface, physicalSize: key.context.physicalSize).map(\.mesh)
                    }
                    geometry = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                }
                var shapes: [ShapeResource] = []
                for mesh in geometry {
                    try Task.checkCancellation()
                    // Static collision indices are UInt16. Partition complete triangles rather
                    // than convexifying an area (which would seal its holes).
                    for offset in stride(from: 0, to: mesh.indices.count, by: 65_535) {
                        let end = min(offset + 65_535, mesh.indices.count)
                        let positions = mesh.indices[offset..<end].map { mesh.positions[Int($0)] }
                        let faces = positions.indices.map(UInt16.init)
                        shapes.append(try await ShapeResource.generateStaticMesh(positions: positions, faceIndices: faces))
                    }
                }
                guard !Task.isCancelled, let self, let record, self.records[input.id] === record,
                      record.appliedKey == key, record.key == key, record.collisionRequest == request, self.spatialHitTesting,
                      record.entity.isEnabled, let currentIdentity = record.entity.components[DioramaMarkerIdentity.self],
                      self.root?.selection?.tag(for: currentIdentity) != nil else { return }
                record.entity.components.set(CollisionComponent(shapes: shapes))
                record.entity.components.set(InputTargetComponent())
                record.collisionKey = key; record.collisionTask = nil
            } catch {
                if record?.collisionRequest == request { record?.collisionTask = nil }
            }
        }
    }
}
