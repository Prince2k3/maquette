import CoreGraphics
import Darwin
import RealityKit
import SwiftUI
import Testing
import simd
@testable import Maquette

/// CPU/resource diagnostics, not GPU frame timings or portable timing assertions.
/// Run in Release with MAQUETTE_RUN_CONTENT_BENCHMARK=1.
@Suite("Map content release benchmarks", .serialized, .enabled(
    if: ProcessInfo.processInfo.environment["MAQUETTE_RUN_CONTENT_BENCHMARK"] == "1",
    "Opt in with MAQUETTE_RUN_CONTENT_BENCHMARK=1 and build in release mode"
))
@MainActor
struct MapContentBenchmark {
    @Test("Separate surface preparation, draping and GPU buffer work")
    func imageStages() throws {
        let (root, proxy) = try OverlayRenderFixture.make(resolution: 256)
        let clock = ContinuousClock()
        var surface: OverlaySurfaceMesh?
        let prepare = try clock.measure {
            surface = try OverlaySurfaceMesh(terrain: #require(root.terrain?.surfaceBuffers))
        }
        let projection = try #require(proxy.projection as? TerrainProjection)
        let bounds = try #require(GeographicBounds(enclosing: [
            projection.anchor.coordinate(forDioramaX: -0.4, z: -0.4),
            projection.anchor.coordinate(forDioramaX: 0.4, z: 0.4)
        ]))
        var layers: [DioramaOverlayLayer] = []
        let drape = try clock.measure {
            layers = try DioramaOverlayGeometryBuilder.build(shape: .image(bounds), style: .init(), proxy: proxy,
                                                           surface: surface, physicalSize: 1)
        }
        let resource = OverlayMeshResource()
        let mesh = try #require(layers.first?.mesh)
        try resource.update(mesh)
        let buffers = try clock.measure { try resource.update(mesh) }
        print("STAGES image: prepare \(milliseconds(prepare)) ms; drape \(milliseconds(drape)) ms; warm buffers \(milliseconds(buffers)) ms; vertices \(mesh.positions.count)")
        let refit = try clock.measure {
            _ = try OverlaySurfaceMesh(terrain: #require(root.terrain?.surfaceBuffers), reusing: surface)
        }
        let path = (0..<10_000).map { index in
            let x = Double(index) / 9_999 * 0.8 - 0.4
            return OverlayVertex(point: .init(x, sin(x * 12) * 0.15))
        }
        var distances = [0.0]
        for i in 1..<path.count { distances.append(distances[i - 1] + simd_distance(path[i].point, path[i - 1].point)) }
        var footprint: [OverlayTriangle] = []
        let planar = try clock.measure {
            footprint = try OverlayStyledStroke.build(path, widths: .init(repeating: 0.001, count: path.count),
                distances: distances, style: .init(width: .physicalMeters(0.001)),
                boundary: proxy.configuration.boundary.vertices.map { .init(point: SIMD2<Double>($0)) })
        }
        let pathDrape = try clock.measure { _ = try surface?.drape(footprint, elevationToY: { $0 }) }
        print("STAGES refit \(milliseconds(refit)) ms; path footprint \(milliseconds(planar)) ms; path drape \(milliseconds(pathDrape)) ms")
        let rings = [300, 100].enumerated().map { ring, count in
            (0..<count).map { i in
                let angle = Double(i) / Double(count) * .pi * 2
                let radius = ring == 0 ? 0.06 : 0.025
                return OverlayVertex(point: SIMD2(cos(angle), sin(angle)) * radius)
            }
        }
        var polygon: [OverlayTriangle] = []
        let polygonPrepare = try clock.measure {
            polygon = try OverlayAreaGeometry.clip(OverlayPolygonTessellator.triangulate(rings: rings),
                boundary: proxy.configuration.boundary.vertices.map { .init(point: SIMD2<Double>($0)) })
        }
        var polygonMesh = OverlayMesh()
        let polygonDrape = try clock.measure {
            polygonMesh = try #require(surface).drapeArea(polygon, rings: rings, altitude: .clampToGround,
                                                        lift: 0.002, elevationToY: { $0 })
        }
        let polygonResource = OverlayMeshResource()
        try polygonResource.update(polygonMesh)
        let polygonBuffer = try clock.measure { try polygonResource.update(polygonMesh) }
        print("STAGES one polygon: prepare \(milliseconds(polygonPrepare)) ms; drape \(milliseconds(polygonDrape)) ms; buffer \(milliseconds(polygonBuffer)) ms; vertices \(polygonMesh.positions.count)")

    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    private func residentMiB() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : nil
    }

    @Test("100 native label factories, reconciliation and layout")
    func labels() throws {
        let content = DioramaContentGroup {
            for index in 0..<100 {
                DioramaAnnotation("Label \(index)", coordinate: Coordinate(latitude: 36, longitude: -112), id: "label-\(index)") {
                    Label("Label \(index)", systemImage: "mappin").padding(4)
                }
            }
        }
        var resolver = DioramaContentIdentityResolver()
        let registry = DioramaAnnotationRegistry()
        registry.reconcile(resolver.resolve(content))
        let lifetimes = registry.orderedRecords.map(\.lifetimeID)
        let candidates = (0..<100).map { index in
            DioramaAnnotationLayout.Candidate(id: "label-\(index)",
                frame: CGRect(x: index % 10 * 100, y: index / 10 * 30, width: 80, height: 20),
                priority: 0, depth: 1, allowsOverlap: false)
        }
        var visible: [String] = []
        let elapsed = ContinuousClock().measure {
            for _ in 0..<100 {
                registry.reconcile(resolver.resolve(content))
                for record in registry.orderedRecords { _ = record.factory.makeView() }
                visible = DioramaAnnotationLayout.visible(candidates)
            }
        }
        #expect(registry.orderedRecords.map(\.lifetimeID) == lifetimes)
        #expect(registry.records.count == 100)
        #expect(visible.count == 64)
        print("CONTENT labels: 100 hosted candidates; 64 visible cap; \(milliseconds(elapsed) / 100) ms/reconcile+factories+layout; zero registry record replacements. SwiftUI layout/render excluded.")
    }

    @Test("10,000-point path")
    func path() async throws {
        let (root, proxy) = try OverlayRenderFixture.make(resolution: 256)
        let projection = try #require(proxy.projection as? TerrainProjection)
        let coordinates = (0..<10_000).map { index in
            let x = Double(index) / 9_999 * 0.8 - 0.4
            return projection.anchor.coordinate(forDioramaX: x, z: sin(x * 12) * 0.15)
        }
        let content = DioramaContentGroup {
            DioramaPolyline(coordinates: coordinates, id: "path")
                .stroke(.orange, width: .physicalMeters(0.001))
        }
        try await exercise(root: root, proxy: proxy, content: content, label: "path 10000 points", expectedRecords: 1)
    }

    @Test("10,000 polygon vertices including holes")
    func polygons() async throws {
        let (root, proxy) = try OverlayRenderFixture.make(resolution: 256)
        let projection = try #require(proxy.projection as? TerrainProjection)
        func ring(_ index: Int, radius: Double, count: Int) -> LinearRing {
            let x = Double(index % 5) * 0.16 - 0.32
            let z = Double(index / 5) * 0.16 - 0.32
            return LinearRing((0..<count).map { vertex in
                let angle = Double(vertex) / Double(count) * .pi * 2
                return projection.anchor.coordinate(forDioramaX: x + cos(angle) * radius, z: z + sin(angle) * radius)
            })
        }
        let polygons = (0..<25).map {
            Maquette.Polygon(exterior: ring($0, radius: 0.06, count: 300), holes: [ring($0, radius: 0.025, count: 100)])
        }
        #expect(polygons.reduce(0) { $0 + ($1.exterior?.open.count ?? 0) + $1.holes.reduce(0) { $0 + $1.open.count } } == 10_000)
        let content = DioramaContentGroup {
            for index in polygons.indices { DioramaPolygon(polygons[index], id: "polygon-\(index)").fill(.green) }
        }
        try await exercise(root: root, proxy: proxy, content: content, label: "25 polygons 10000 vertices 25 holes", expectedRecords: 25)
    }

    @Test("Four 2048-pixel images retain uploads across pan and reconciliation")
    func images() async throws {
        let (root, proxy) = try OverlayRenderFixture.make(resolution: 256)
        let projection = try #require(proxy.projection as? TerrainProjection)
        let images = try (0..<4).map { index in
            let context = try #require(CGContext(data: nil, width: 2048, height: 2048, bitsPerComponent: 8,
                bytesPerRow: 2048 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: CGFloat(index) / 4, green: 0.5, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 2048, height: 2048))
            return DioramaImageResource(id: "image-\(index)", revision: "1", image: try #require(context.makeImage()))
        }
        let bounds = try #require(GeographicBounds(enclosing: [
            projection.anchor.coordinate(forDioramaX: -0.4, z: -0.4),
            projection.anchor.coordinate(forDioramaX: 0.4, z: 0.4)
        ]))
        let content = DioramaContentGroup {
            for index in images.indices { DioramaImageOverlay(image: images[index], bounds: bounds, id: "image-\(index)").opacity(0.25) }
        }
        try await exercise(root: root, proxy: proxy, content: content, label: "4 images 2048x2048 RGBA", expectedRecords: 4, expectedUploads: 4)
    }

    private func exercise(root: DioramaEntity, proxy: DioramaProxy, content: DioramaContentGroup,
                          label: String, expectedRecords: Int, expectedUploads: Int = 0) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let memoryBefore = residentMiB()
        root.applyContent(content, using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        let initial = start.duration(to: clock.now)
        #expect(root.overlayRenderer.diagnostics.isEmpty)
        #expect(root.overlayRenderer.records.count == expectedRecords)
        #expect(root.overlayRenderer.records.values.allSatisfy { !$0.layers.isEmpty })
        let records = root.overlayRenderer.records
        let terrain = try #require(root.terrain)
        let terrainMesh = try #require(terrain.surface?.model?.mesh)
        let warmMemory = residentMiB()
        let builds = root.overlayRenderer.geometryBuildCount
        for _ in 0..<10 { root.applyContent(content, using: proxy, physicalSize: 1) }
        await root.overlayRenderer.waitUntilIdle()
        #expect(root.overlayRenderer.geometryBuildCount == builds)
        let completionStart = root.overlayRenderer.reconciliationDuration
        var panTime = Duration.zero
        var panTimes: [Double] = []
        var samples: [Double] = []
        for step in 1...20 {
            let offset = SIMD2<Float>(Float(step % 5) * 0.002, 0)
            var projection = try #require(proxy.projection as? TerrainProjection)
            projection.panOffset = offset
            let moved = DioramaProxy(configuration: proxy.configuration, projection: projection)
            let panStart = clock.now
            terrain.setPanOffset(offset)
            root.applyContent(content, using: moved, physicalSize: 1)
            await root.overlayRenderer.waitUntilIdle()
            let elapsed = panStart.duration(to: clock.now)
            panTime += elapsed
            panTimes.append(milliseconds(elapsed))
            if let memory = residentMiB() { samples.append(memory) }
            #expect(root.overlayRenderer.diagnostics.isEmpty)
            #expect(root.overlayRenderer.records.count == expectedRecords)
            for (id, record) in records { #expect(root.overlayRenderer.records[id] === record) }
            #expect(terrain.surface?.model?.mesh === terrainMesh)
            #expect(root.overlayRenderer.textureUploadCount == expectedUploads)
        }
        let panCompletion = root.overlayRenderer.reconciliationDuration - completionStart
        print("CONTENT main actor completion mean \(milliseconds(panCompletion) / 20) ms")
        let vertices = root.overlayRenderer.records.values.reduce(0) { count, record in
            count + record.layers.values.reduce(0) { $0 + $1.mesh.positions.count }
        }
        let base = try #require(proxy.projection as? TerrainProjection)
        let tile = TileMath.tileXY(for: Coordinate(proxy.configuration.center), zoom: base.anchor.zoom)
        var zoomTime = Duration.zero
        var zoomTimes: [Double] = []
        for step in 1...10 {
            let scale = 1 + Float(step % 5) * 0.05
            let field = TerrainHeightField(grids: [.init(width: 2, height: 2, values: [100, 200, 150, 250])],
                tilePositions: [(tile.x, tile.y)], anchor: base.anchor.scaled(by: Double(scale)),
                elevationScale: base.heightField.elevationScale / scale, baselineElevation: base.heightField.baselineElevation)
            let start = clock.now
            terrain.setTerrain(field, surfaceMaterial: nil, panOffset: .zero, groundScale: scale)
            root.applyContent(content, using: DioramaProxy(configuration: proxy.configuration,
                projection: TerrainProjection(heightField: field)), physicalSize: 1)
            await root.overlayRenderer.waitUntilIdle()
            let elapsed = start.duration(to: clock.now)
            zoomTime += elapsed
            zoomTimes.append(milliseconds(elapsed))
            #expect(root.overlayRenderer.diagnostics.isEmpty)
            #expect(root.overlayRenderer.textureUploadCount == expectedUploads)
        }
        var inputTimes: [Double] = []
        var completedFrames = 0
        var inputIntervals: [Double] = []
        for step in 1...30 {
            let frameStart = clock.now
            let offset = SIMD2<Float>(Float(step % 9) * 0.001, 0)
            let moved = DioramaProxy(configuration: proxy.configuration,
                projection: TerrainProjection(heightField: base.heightField, panOffset: offset))
            let elapsed = clock.measure {
                if step == 1 { terrain.setTerrain(base.heightField, surfaceMaterial: nil, panOffset: offset, groundScale: 1) }
                else { terrain.setPanOffset(offset) }
                root.applyContent(content, using: moved, physicalSize: 1)
            }
            inputTimes.append(milliseconds(elapsed))
            #expect(root.overlayRenderer.activeGeometryJobCount <= expectedRecords)
            try await Task.sleep(for: .milliseconds(16))
            inputIntervals.append(milliseconds(frameStart.duration(to: clock.now)))
            if root.overlayRenderer.records.values.allSatisfy({ $0.appliedKey == $0.key }) { completedFrames += 1 }
        }
        await root.overlayRenderer.waitUntilIdle()
        #expect(root.overlayRenderer.records.values.allSatisfy { $0.appliedKey == $0.key })
        #expect(root.overlayRenderer.textureUploadCount == expectedUploads)
        inputTimes.sort()
        inputIntervals.sort()
        print("CONTENT zoom mean \(milliseconds(zoomTime) / 10) ms; nominal 16ms-input main actor p95 \(inputTimes[Int(Double(inputTimes.count - 1) * 0.95)]) ms; overlays completed before next input \(completedFrames)/30; retained jobs \(root.overlayRenderer.activeGeometryJobCount)")
        print("CONTENT nominal 16ms input: observed interval p95 \(inputIntervals[Int(Double(inputIntervals.count - 1) * 0.95)]) ms")
        func p95(_ samples: [Double]) -> Double {
            samples.sorted()[Int(ceil(Double(samples.count) * 0.95)) - 1]
        }
        print("CONTENT completed pan p95/max \(p95(panTimes))/\(panTimes.max()!) ms; zoom p95/max \(p95(zoomTimes))/\(zoomTimes.max()!) ms")
        print("CONTENT \(label): initial \(milliseconds(initial)) ms; pan rebuild mean \(milliseconds(panTime) / 20) ms; output vertices \(vertices); uploads \(root.overlayRenderer.textureUploadCount); zero record replacements; terrain mesh retained.")
        print("CONTENT RSS MiB: before \(String(describing: memoryBefore)); warm \(String(describing: warmMemory)); cycle range \(String(describing: samples.min()))...\(String(describing: samples.max())). Process resident samples include allocator caches; exclude GPU/heap attribution and do not prove bounded long-run memory.")
    }
}
