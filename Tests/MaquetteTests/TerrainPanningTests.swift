import CoreLocation
import Foundation
import Testing
import simd
@testable import Maquette

@Suite("Terrain Panning Tests")
struct TerrainPanningTests {
    /// A height field with a west-to-east elevation ramp, so a pan along X is directly observable.
    private func rampHeightField(extent: Float = 2.0) -> TerrainHeightField {
        TerrainHeightField(
            grids: [ElevationGrid(width: 2, height: 2, values: [0, 1000, 0, 1000])],
            tilePositions: [(x: 0, y: 0)],
            extent: SIMD2(repeating: extent),
            elevationScale: 0.0002
        )
    }

    private var boundary: DioramaBoundary {
        DioramaBoundary.make(shape: .circular, extent: SIMD2(1.0, 1.0))
    }

    private func geometry(panOffset: SIMD2<Float>) -> TerrainSolidGenerator.Geometry {
        TerrainSolidGenerator.buildGeometry(
            heightField: rampHeightField(),
            boundary: boundary,
            baseDepth: 0.1,
            includesWalls: true,
            includesBottom: true,
            resolution: 32,
            panOffset: panOffset
        )
    }

    // MARK: - Sampling

    @Test("Panning shifts which terrain appears under the outline")
    func panShiftsSampledTerrain() {
        let centred = geometry(panOffset: .zero)
        let panned = geometry(panOffset: SIMD2(0.4, 0))

        let centredMean = centred.top.positions.map(\.y).reduce(0, +) / Float(centred.top.positions.count)
        let pannedMean = panned.top.positions.map(\.y).reduce(0, +) / Float(panned.top.positions.count)

        // Sampling further east on a west-to-east ramp must raise the terrain under the chunk.
        #expect(pannedMean > centredMean + 0.01,
                "Panning east should reveal higher ground (\(centredMean) to \(pannedMean))")
    }

    @Test("Panning leaves the chunk's footprint untouched")
    func panPreservesFootprint() {
        let centred = geometry(panOffset: .zero)
        let panned = geometry(panOffset: SIMD2(0.35, -0.2))

        #expect(centred.top.positions.count == panned.top.positions.count)
        #expect(centred.top.indices == panned.top.indices)

        for (a, b) in zip(centred.top.positions, panned.top.positions) {
            #expect(abs(a.x - b.x) < 1e-6, "Horizontal position must not move when panning")
            #expect(abs(a.z - b.z) < 1e-6, "Horizontal position must not move when panning")
        }
    }

    // MARK: - Resampling

    @Test("Re-sampling matches a fresh build at the same offset")
    func resampleMatchesFreshBuild() {
        let offset = SIMD2<Float>(0.3, 0.15)
        var resampled = geometry(panOffset: .zero)
        TerrainSolidGenerator.resample(&resampled, heightField: rampHeightField(), panOffset: offset)

        let rebuilt = geometry(panOffset: offset)

        // The frozen wall height differs between the two, so compare the surface only.
        #expect(resampled.top.positions.count == rebuilt.top.positions.count)
        for (a, b) in zip(resampled.top.positions, rebuilt.top.positions) {
            #expect(abs(a.y - b.y) < 1e-5, "Re-sampled height \(a.y) should match rebuilt \(b.y)")
        }
        for (a, b) in zip(resampled.top.uvs, rebuilt.top.uvs) {
            #expect(abs(a.x - b.x) < 1e-5 && abs(a.y - b.y) < 1e-5)
        }
    }

    @Test("Re-sampling keeps wall bottoms pinned to the base")
    func resampleKeepsWallBottomsPinned() {
        let baseDepth: Float = 0.1
        var geo = geometry(panOffset: .zero)
        TerrainSolidGenerator.resample(&geo, heightField: rampHeightField(), panOffset: SIMD2(0.4, 0))

        // Wall quads are emitted top, bottom, top, bottom.
        for index in stride(from: 1, to: geo.walls.positions.count, by: 2) {
            #expect(abs(geo.walls.positions[index].y + baseDepth) < 1e-6,
                    "Wall base moved while panning")
        }
    }

    @Test("Re-sampled wall tops still meet the terrain")
    func resampledWallsMeetSurface() {
        let heightField = rampHeightField()
        let offset = SIMD2<Float>(-0.3, 0.2)
        var geo = geometry(panOffset: .zero)
        TerrainSolidGenerator.resample(&geo, heightField: heightField, panOffset: offset)

        for index in stride(from: 0, to: geo.walls.positions.count, by: 2) {
            let position = geo.walls.positions[index]
            let expected = heightField.surfaceY(atX: position.x + offset.x, z: position.z + offset.y)
            #expect(abs(position.y - expected) < 1e-5,
                    "Wall top separated from the terrain after panning")
        }
    }

    @Test("Panning does not disturb the bottom face")
    func bottomFaceIsStatic() {
        var geo = geometry(panOffset: .zero)
        let before = geo.bottom.positions
        TerrainSolidGenerator.resample(&geo, heightField: rampHeightField(), panOffset: SIMD2(0.5, 0.5))
        #expect(geo.bottom.positions == before)
    }

    @Test("Strata stay put while the terrain moves beneath them")
    func wallTextureReferenceIsFrozen() {
        var geo = geometry(panOffset: .zero)
        let frozen = geo.resampling.wallHeight
        TerrainSolidGenerator.resample(&geo, heightField: rampHeightField(), panOffset: SIMD2(0.45, 0))

        #expect(geo.resampling.wallHeight == frozen,
                "A moving wall height would slide the strata bands as the terrain pans")
    }

    // MARK: - Configuration

    @Test("Pan range widens the fetched region without changing scale")
    func panRangeWidensRegion() {
        let fixed = DioramaConfiguration(
            center: CLLocationCoordinate2D(latitude: 36, longitude: -112),
            radiusMeters: 5000,
            physicalSize: 0.8
        )
        let pannable = DioramaConfiguration(
            center: CLLocationCoordinate2D(latitude: 36, longitude: -112),
            radiusMeters: 5000,
            physicalSize: 0.8,
            panRange: 0.5
        )

        #expect(fixed.terrainFetchRadiusMeters == 5000)
        #expect(pannable.terrainFetchRadiusMeters == 7500)
        // Same scale means the chunk keeps its true proportions either way.
        #expect(abs(fixed.geographicScale - pannable.geographicScale) < 1e-9)
        #expect(abs(pannable.terrainRegionExtent.x - 1.2) < 1e-6)
    }

    @Test("Pan limits keep the chunk inside the fetched region")
    func panLimits() {
        let fixed = DioramaConfiguration(
            center: CLLocationCoordinate2D(latitude: 36, longitude: -112),
            radiusMeters: 5000,
            physicalSize: 0.8
        )
        #expect(fixed.maximumPanOffset.x == 0, "Without a pan range there is nowhere to pan")

        let pannable = DioramaConfiguration(
            center: CLLocationCoordinate2D(latitude: 36, longitude: -112),
            radiusMeters: 5000,
            physicalSize: 0.8,
            panRange: 0.5
        )
        // Region is 1.2 wide, chunk is 0.8, so 0.2 of margin on each side.
        #expect(abs(pannable.maximumPanOffset.x - 0.2) < 1e-6)
        #expect(abs(pannable.maximumPanOffset.y - 0.2) < 1e-6)
    }

    @Test("Negative pan ranges are clamped away")
    func negativePanRangeClamped() {
        let configuration = DioramaConfiguration(
            center: CLLocationCoordinate2D(latitude: 36, longitude: -112),
            radiusMeters: 5000,
            panRange: -1
        )
        #expect(configuration.panRange == 0)
    }
}
