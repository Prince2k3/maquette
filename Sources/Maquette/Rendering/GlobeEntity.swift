import CoreGraphics
import Foundation
import RealityKit
import os

/// A textured globe: the whole world on one sphere, wearing the same raster imagery the chunk does.
///
/// The mesh comes from ``GlobeGeometry``, which spaces its rows in Web Mercator so the world image
/// goes on without reprojection. The imagery is the provider's own tiles at a low zoom, composited
/// by ``DioramaMaterials/compositeSatelliteImage(tiles:minX:minY:tilesWide:tilesTall:)`` — the same
/// function the chunk's mosaic goes through, given the whole world as its window.
///
/// The material is unlit, for the reason the photorealistic path's is: satellite imagery is already
/// lit by the real sun, and lighting it again dims whichever half of the world faces away from the
/// scene's key light.
@MainActor
final class GlobeEntity: Entity {
    /// The sphere's radius in diorama meters.
    public private(set) var radius: Float

    /// The textured sphere.
    public private(set) var surface: ModelEntity?

    /// The photographic world mosaic the sphere was built with.
    ///
    /// Kept so an effect's restyle can read it and be undone without refetching the world — the
    /// texture on the material cannot be read back, which is the same reason
    /// ``DioramaEffectContext`` carries the chunk's mosaic as an image.
    public private(set) var worldImage: CGImage?

    // Nonisolated because the fetch runs off the main actor and logs its own failures from there.
    private nonisolated static let logger = Logger(maquette: "GlobeEntity")

    /// Creates a globe from an already-composited world image.
    ///
    /// - Parameters:
    ///   - radius: Sphere radius in diorama meters.
    ///   - worldImage: The whole world in one equirectangular-in-Mercator image — north-up, spanning
    ///     longitude −180…180 and latitude ±85.0511°. Passing `nil` renders the sphere in a flat
    ///     colour, which is what a failed fetch should look like rather than nothing at all.
    ///   - rows: Latitude bands. See ``GlobeGeometry/build(radius:rows:columns:)``.
    ///   - columns: Longitude divisions.
    public init(
        radius: Float,
        worldImage: CGImage?,
        rows: Int = 128,
        columns: Int = 256
    ) throws {
        self.radius = radius
        self.worldImage = worldImage
        super.init()
        self.name = "Globe"

        let surfaceGeometry = GlobeGeometry.build(radius: radius, rows: rows, columns: columns)
        let mesh = try Self.buildMesh(from: surfaceGeometry)

        let model = ModelEntity(mesh: mesh, materials: [Self.material(for: worldImage)])
        model.name = "GlobeSurface"
        addChild(model)
        self.surface = model
    }

    @MainActor required init() {
        self.radius = 1
        super.init()
    }

    // MARK: - Imagery

    /// Fetches the whole world at the given zoom and composites it into one image.
    ///
    /// Zoom 2 is sixteen tiles and a 1024-pixel world, which is about as coarse as a globe can look
    /// and still read as the Earth; zoom 3 is sixty-four tiles for twice the detail. Tiles are
    /// fetched concurrently and a tile that fails is simply left out of the mosaic — the compositing
    /// skips what it cannot decode, so a patchy world is better than no world. Only a total failure
    /// throws.
    ///
    /// Runs off the main actor: it is network and Core Graphics, and the texture upload is the only
    /// part that has to come back.
    public static func fetchWorldImage(
        provider: any TileProvider,
        cache: TileCache,
        zoom: Int = 2
    ) async throws -> CGImage {
        let zoom = max(0, zoom)
        let side = 1 << zoom

        let tiles = await withTaskGroup(of: (x: Int, y: Int, data: Data)?.self) { group in
            for y in 0..<side {
                for x in 0..<side {
                    group.addTask {
                        do {
                            let data = try await cache.cachedOrFetch(
                                x: x, y: y, zoom: zoom, provider: provider
                            )
                            return (x: x, y: y, data: data)
                        } catch {
                            logger.debug("Globe tile \(zoom)/\(x)/\(y) failed: \(error.localizedDescription)")
                            return nil
                        }
                    }
                }
            }
            var collected: [(x: Int, y: Int, data: Data)] = []
            for await tile in group {
                if let tile { collected.append(tile) }
            }
            return collected
        }

        guard !tiles.isEmpty else {
            throw DioramaError.meshGenerationFailed(reason: "No world imagery tiles could be fetched")
        }
        if tiles.count < side * side {
            logger.notice("Globe imagery is partial: \(tiles.count) of \(side * side) tiles at zoom \(zoom)")
        }

        return try DioramaMaterials.compositeSatelliteImage(
            tiles: tiles, minX: 0, minY: 0, tilesWide: side, tilesTall: side
        )
    }

    /// Fetches the world and builds the globe in one step.
    public static func make(
        radius: Float,
        provider: any TileProvider = SatelliteTileProvider(),
        cache: TileCache = TileCache(),
        zoom: Int = 2,
        rows: Int = 128,
        columns: Int = 256
    ) async throws -> GlobeEntity {
        let image = try await fetchWorldImage(provider: provider, cache: cache, zoom: zoom)
        return try GlobeEntity(radius: radius, worldImage: image, rows: rows, columns: columns)
    }

    // MARK: - Placement

    /// Where a coordinate sits on this globe's surface, in the globe's own space.
    /// Repaints the sphere with a restyled world image, leaving the photographic original in hand.
    ///
    /// - Parameter opacity: How solid the restyled sphere is. Below 1 the material blends, which
    ///   is what lets a hologram's globe read as projected light rather than a painted marble.
    public func applyEffectImagery(_ image: CGImage, opacity: Float = 1) {
        var material = Self.material(for: image)
        if opacity < 1, var unlit = material as? UnlitMaterial {
            unlit.blending = .transparent(opacity: .init(floatLiteral: max(0, opacity)))
            material = unlit
        }
        surface?.model?.materials = [material]
    }

    /// Puts the photographic mosaic back.
    public func restoreImagery() {
        surface?.model?.materials = [Self.material(for: worldImage)]
    }

    public func position(for coordinate: Coordinate) -> SIMD3<Float> {
        GlobeGeometry.position(for: coordinate, radius: radius)
    }

    // MARK: - Private

    private static func material(for worldImage: CGImage?) -> RealityKit.Material {
        guard let worldImage else {
            var fallback = UnlitMaterial(color: .init(red: 0.16, green: 0.22, blue: 0.30, alpha: 1))
            fallback.faceCulling = .back
            return fallback
        }
        do {
            let texture = try TextureResource(image: worldImage, options: .init(semantic: .color))
            var material = UnlitMaterial()
            material.color = .init(tint: .white, texture: .init(texture))
            material.faceCulling = .back
            return material
        } catch {
            logger.error("Globe texture upload failed: \(error.localizedDescription)")
            return UnlitMaterial(color: .init(red: 0.16, green: 0.22, blue: 0.30, alpha: 1))
        }
    }

    private static func buildMesh(from surface: GlobeGeometry.Surface) throws -> MeshResource {
        var descriptor = MeshDescriptor(name: "globe")
        descriptor.positions = MeshBuffers.Positions(surface.positions)
        descriptor.normals = MeshBuffers.Normals(surface.normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(surface.uvs)
        descriptor.primitives = .triangles(surface.indices)
        do {
            return try MeshResource.generate(from: [descriptor])
        } catch {
            throw DioramaError.meshGenerationFailed(reason: error.localizedDescription)
        }
    }
}
