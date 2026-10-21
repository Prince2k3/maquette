import simd

enum DioramaOverlayShape: Sendable, Equatable {
    case line([Coordinate])
    case polygon(Polygon)
    case circle(Coordinate, Double)
    case image(GeographicBounds)
    var isLine: Bool { if case .line = self { true } else { false } }
}

struct DioramaOverlayInput: Sendable {
    var id: String
    var shape: DioramaOverlayShape
    var annotation: DioramaFeature
}

enum DioramaOverlayLayerKind: Sendable, Hashable { case fill, stroke, image }
struct DioramaOverlayLayer: Sendable {
    var kind: DioramaOverlayLayerKind
    var mesh: OverlayMesh
}

enum DioramaOverlayGeometryBuilder {
    static func build(shape: DioramaOverlayShape, style: DioramaFeatureStyle, proxy: DioramaProxy,
                      surface: OverlaySurfaceMesh?, physicalSize: Float) throws -> [DioramaOverlayLayer] {
        let projection = proxy.projection
        let geographic: OverlayGeographicGeometry
        if let raster = projection as? TerrainProjection { geographic = try .init(projection: raster) }
        else if let ellipsoid = projection as? EllipsoidProjection { geographic = try .init(projection: ellipsoid) }
        else { geographic = try .init(projection: projection, referenceLongitude: proxy.configuration.center.longitude, domain: .ellipsoid) }
        guard style.opacity.isFinite else { throw OverlayGeometryError.nonFiniteInput }
        guard style.altitude == .absolute || surface != nil else { throw OverlayGeometryError.unsupportedSurface }
        let ground = try surface ?? OverlaySurfaceMesh(terrain: .init())
        let boundary = proxy.configuration.boundary.vertices.map { OverlayVertex(point: SIMD2<Double>($0)) }
        let lift = Double(physicalSize) * 0.002
        var result: [DioramaOverlayLayer] = []
        func draped(_ source: [OverlayTriangle], kind: DioramaOverlayLayerKind, rings: [[OverlayVertex]]? = nil) throws {
            let layerLift = lift + (kind == .stroke ? Double(physicalSize) * 0.0002 : 0)
            let mesh: OverlayMesh
            if kind == .image, let ring = rings?.first {
                mesh = try ground.drapeImage(source, ring: ring, altitude: style.altitude, lift: layerLift) {
                    Double(projection.y(forElevation: $0))
                }
            } else if let rings {
                mesh = try ground.drapeArea(source, rings: rings, altitude: style.altitude, lift: layerLift) {
                    Double(projection.y(forElevation: $0))
                }
            } else {
                mesh = try ground.drape(source, using: projection, altitude: style.altitude, lift: layerLift)
            }
            if !mesh.indices.isEmpty { result.append(.init(kind: kind, mesh: mesh)) }
        }
        func coordinate(at vertex: OverlayVertex, fallback: Coordinate) -> Coordinate {
            if let raster = projection as? TerrainProjection {
                return raster.anchor.coordinate(forDioramaX: vertex.point.x + Double(raster.panOffset.x),
                                                 z: vertex.point.y + Double(raster.panOffset.y))
            }
            return fallback
        }
        func stroke(_ vertices: [OverlayVertex], coordinates: [Coordinate], closed: Bool) throws {
            guard vertices.count >= 2 else { return }
            var widths: [Double] = []
            for (i, vertex) in vertices.enumerated() {
                switch style.strokeStyle.width {
                case .physicalMeters(let value): widths.append(Double(value))
                case .geographicMeters(let value):
                    guard value.isFinite, value > 0 else { throw OverlayGeometryError.invalidWidth }
                    let center = coordinates.indices.contains(i) ? coordinates[i] : coordinate(at: vertex, fallback: coordinates[0])
                    let offset = Turf.destination(from: center, meters: value, bearing: 90)
                    let projected = try geographic.project([center, offset])
                    widths.append(simd_distance(projected[0].point, projected[1].point))
                }
            }
            var distances = [0.0]
            for i in 1..<vertices.count {
                let length: Double
                switch style.strokeStyle.width {
                case .physicalMeters: length = simd_distance(vertices[i - 1].point, vertices[i].point)
                case .geographicMeters:
                    let a = coordinates.indices.contains(i - 1) ? coordinates[i - 1] : coordinate(at: vertices[i - 1], fallback: coordinates[0])
                    let b = coordinates.indices.contains(i) ? coordinates[i] : coordinate(at: vertices[i], fallback: coordinates[0])
                    length = Turf.distance(from: a, to: b)
                }
                distances.append(distances[i - 1] + length)
            }
            let triangles = try OverlayStyledStroke.build(vertices, widths: widths, distances: distances,
                style: style.strokeStyle, closed: closed, boundary: boundary)
            try draped(triangles, kind: .stroke)
        }
        switch shape {
        case .line(let coordinates):
            let vertices = try geographic.project(coordinates)
            try stroke(vertices, coordinates: coordinates, closed: false)
        case .polygon(let polygon):
            let rings = try polygon.rings.map { try geographic.project($0.coordinates) }
            let source = try OverlayPolygonTessellator.triangulate(rings: rings)
            try draped(OverlayAreaGeometry.clip(source, boundary: boundary), kind: .fill, rings: rings)
            if style.stroke != nil {
                for (ring, vertices) in zip(polygon.rings, rings) { try stroke(vertices, coordinates: ring.coordinates, closed: true) }
            }
        case .circle(let center, let radius):
            var ring = try geographic.circle(center: center, radius: radius, maximumError: max(1e-7, Double(physicalSize) * 0.0002))
            let source = try OverlayPolygonTessellator.triangulate(rings: [ring])
            try draped(OverlayAreaGeometry.clip(source, boundary: boundary), kind: .fill, rings: [ring])
            if style.stroke != nil, let first = ring.first {
                ring.append(first)
                try stroke(ring, coordinates: ring.map { coordinate(at: $0, fallback: center) }, closed: true)
            }
        case .image(let bounds):
            let ring = try geographic.image(bounds: bounds)
            let source = try OverlayPolygonTessellator.triangulate(rings: [ring])
            try draped(OverlayAreaGeometry.clip(source, boundary: boundary), kind: .image, rings: [ring])
        }
        var merged: [DioramaOverlayLayer] = []
        for layer in result {
            if let i = merged.firstIndex(where: { $0.kind == layer.kind }) {
                let base = merged[i].mesh.positions.count
                guard base + layer.mesh.positions.count < Int(UInt32.max),
                      merged[i].mesh.indices.count + layer.mesh.indices.count <= 600_000 else { throw OverlayGeometryError.budgetExceeded }
                merged[i].mesh.positions += layer.mesh.positions
                merged[i].mesh.normals += layer.mesh.normals
                merged[i].mesh.uvs += layer.mesh.uvs
                merged[i].mesh.indices += layer.mesh.indices.map { $0 + UInt32(base) }
            } else { merged.append(layer) }
        }
        return merged
    }
}
