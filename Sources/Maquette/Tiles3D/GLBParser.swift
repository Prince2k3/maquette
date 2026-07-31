import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import RealityKit
import simd

/// Parses a GLB (glTF Binary) file into RealityKit mesh and material data.
struct GLBParser: Sendable {

    /// Parse result containing mesh geometry and texture data.
    public struct ParsedTile: @unchecked Sendable {
        /// Mesh descriptors for each primitive in the GLB.
        public let meshDescriptors: [MeshDescriptor]
        /// Texture images extracted from the GLB.
        public let textureImages: [CGImage]
        /// Transform matrix from the root node (identity if none specified).
        public let transform: simd_float4x4
        /// Double-precision transform for ECEF accuracy when used as a fallback.
        public let transformDouble: simd_double4x4
        /// CESIUM_RTC center or b3dm RTC_CENTER (ECEF position, Double precision).
        /// When present, mesh vertices are small offsets from this center.
        public let rtcCenter: SIMD3<Double>?
    }

    // MARK: - GLB Constants

    private static let glbMagic: UInt32 = 0x46546C67  // "glTF"
    private static let b3dmMagic: UInt32 = 0x6D643362  // "b3dm"
    private static let i3dmMagic: UInt32 = 0x6D643369  // "i3dm"
    private static let jsonChunkType: UInt32 = 0x4E4F534A  // "JSON"
    private static let binChunkType: UInt32 = 0x004E4942   // "BIN\0"

    // MARK: - Public API

    /// Parses a GLB or b3dm binary blob into mesh + texture data.
    ///
    /// Automatically detects b3dm (Batched 3D Model) format and extracts the
    /// embedded GLB body before parsing.
    ///
    /// - Parameter data: Raw GLB or b3dm file data.
    /// - Returns: Parsed tile with mesh descriptors and textures.
    /// - Throws: `DioramaError.glbParsingFailed` or `DioramaError.unsupportedTileFormat` for Draco.
    public static func parse(_ data: Data) throws -> ParsedTile {
        guard data.count >= 12 else {
            throw DioramaError.glbParsingFailed(reason: "Data too small for GLB header")
        }

        // Read header
        var magic = data.readUInt32(at: 0)
        let version = data.readUInt32(at: 4)

        // b3dm/i3dm: extract embedded GLB body
        let glbData: Data
        if magic == b3dmMagic || magic == i3dmMagic {
            // Extract RTC_CENTER from b3dm feature table (if present)
            let b3dmRTC = extractRTCCenterFromBatchedFormat(data)
            glbData = try extractGLBFromBatchedFormat(data)
            guard glbData.count >= 12 else {
                throw DioramaError.glbParsingFailed(reason: "Embedded GLB too small")
            }
            magic = glbData.readUInt32(at: 0)
            var parsed = try parseGLB(glbData, magic: magic, version: glbData.readUInt32(at: 4))
            // b3dm RTC_CENTER takes precedence if CESIUM_RTC wasn't found in the GLB
            if parsed.rtcCenter == nil, let rtc = b3dmRTC {
                parsed = ParsedTile(
                    meshDescriptors: parsed.meshDescriptors,
                    textureImages: parsed.textureImages,
                    transform: parsed.transform,
                    transformDouble: parsed.transformDouble,
                    rtcCenter: rtc
                )
            }
            return parsed
        }

        return try parseGLB(data, magic: magic, version: version)
    }

    /// Extracts the GLB body from a b3dm or i3dm container.
    ///
    /// b3dm layout: [28-byte header][Feature Table JSON][Feature Table Binary][Batch Table JSON][Batch Table Binary][GLB body]
    private static func extractGLBFromBatchedFormat(_ data: Data) throws -> Data {
        guard data.count >= 28 else {
            throw DioramaError.glbParsingFailed(reason: "b3dm header too small")
        }

        let featureTableJSONByteLength = Int(data.readUInt32(at: 12))
        let featureTableBinaryByteLength = Int(data.readUInt32(at: 16))
        let batchTableJSONByteLength = Int(data.readUInt32(at: 20))
        let batchTableBinaryByteLength = Int(data.readUInt32(at: 24))

        let glbOffset = 28
            + featureTableJSONByteLength
            + featureTableBinaryByteLength
            + batchTableJSONByteLength
            + batchTableBinaryByteLength

        guard glbOffset < data.count else {
            throw DioramaError.glbParsingFailed(reason: "b3dm GLB offset (\(glbOffset)) exceeds data size (\(data.count))")
        }

        return Data(data[glbOffset...])
    }

    private static func parseGLB(_ data: Data, magic: UInt32, version: UInt32) throws -> ParsedTile {

        guard magic == glbMagic else {
            throw DioramaError.glbParsingFailed(reason: "Invalid GLB magic: \(String(magic, radix: 16))")
        }
        guard version == 2 else {
            throw DioramaError.glbParsingFailed(reason: "Unsupported GLB version: \(version)")
        }

        // Parse chunks
        var jsonData: Data?
        var binData: Data?
        var offset = 12

        while offset + 8 <= data.count {
            let chunkLength = Int(data.readUInt32(at: offset))
            let chunkType = data.readUInt32(at: offset + 4)
            let chunkStart = offset + 8

            guard chunkStart + chunkLength <= data.count else { break }

            let chunkData = data[chunkStart..<(chunkStart + chunkLength)]

            switch chunkType {
            case jsonChunkType:
                jsonData = Data(chunkData)
            case binChunkType:
                binData = Data(chunkData)
            default:
                break // Skip unknown chunks
            }

            offset = chunkStart + chunkLength
        }

        guard let json = jsonData else {
            throw DioramaError.glbParsingFailed(reason: "No JSON chunk found")
        }

        // Parse glTF JSON
        let gltf: GLTFRoot
        do {
            gltf = try JSONDecoder().decode(GLTFRoot.self, from: json)
        } catch {
            throw DioramaError.glbParsingFailed(reason: "Failed to decode glTF JSON: \(error)")
        }

        // Check for Draco compression
        if let required = gltf.extensionsRequired, required.contains("KHR_draco_mesh_compression") {
            throw DioramaError.unsupportedTileFormat(reason: "Draco mesh compression not supported")
        }

        let bin = binData ?? Data()

        // Extract meshes
        var meshDescriptors: [MeshDescriptor] = []
        for (meshIndex, mesh) in (gltf.meshes ?? []).enumerated() {
            for (primIndex, primitive) in mesh.primitives.enumerated() {
                if let descriptor = try extractPrimitive(
                    primitive,
                    accessors: gltf.accessors ?? [],
                    bufferViews: gltf.bufferViews ?? [],
                    bin: bin,
                    name: "mesh\(meshIndex)_prim\(primIndex)"
                ) {
                    meshDescriptors.append(descriptor)
                }
            }
        }

        // Extract textures
        var textureImages: [CGImage] = []
        for image in gltf.images ?? [] {
            if let bufferView = image.bufferView,
               bufferView < (gltf.bufferViews ?? []).count {
                let view = gltf.bufferViews![bufferView]
                let start = view.byteOffset ?? 0
                let length = view.byteLength
                guard start + length <= bin.count else { continue }
                let imageData = bin[start..<(start + length)]
                if let cgImage = decodeImage(Data(imageData)) {
                    textureImages.append(cgImage)
                }
            }
        }

        // Extract root node transform (both Float and Double precision)
        let transformDouble: simd_double4x4
        if let scenes = gltf.scenes, let scene = scenes.first,
           let nodes = scene.nodes, let firstNodeIndex = nodes.first,
           let allNodes = gltf.nodes, firstNodeIndex < allNodes.count {
            let node = allNodes[firstNodeIndex]
            if let matrix = node.matrix, matrix.count == 16 {
                // Explicit matrix
                transformDouble = simd_double4x4(
                    SIMD4<Double>(matrix[0], matrix[1], matrix[2], matrix[3]),
                    SIMD4<Double>(matrix[4], matrix[5], matrix[6], matrix[7]),
                    SIMD4<Double>(matrix[8], matrix[9], matrix[10], matrix[11]),
                    SIMD4<Double>(matrix[12], matrix[13], matrix[14], matrix[15])
                )
            } else if node.translation != nil || node.rotation != nil || node.scale != nil {
                // Build from TRS (Translation × Rotation × Scale)
                transformDouble = buildTRSTransform(
                    translation: node.translation,
                    rotation: node.rotation,
                    scale: node.scale
                )
            } else {
                transformDouble = .init(diagonal: .one)
            }
        } else {
            transformDouble = .init(diagonal: .one)
        }

        // Float-precision copy for legacy callers
        let transform = simd_float4x4(
            SIMD4<Float>(Float(transformDouble.columns.0.x), Float(transformDouble.columns.0.y), Float(transformDouble.columns.0.z), Float(transformDouble.columns.0.w)),
            SIMD4<Float>(Float(transformDouble.columns.1.x), Float(transformDouble.columns.1.y), Float(transformDouble.columns.1.z), Float(transformDouble.columns.1.w)),
            SIMD4<Float>(Float(transformDouble.columns.2.x), Float(transformDouble.columns.2.y), Float(transformDouble.columns.2.z), Float(transformDouble.columns.2.w)),
            SIMD4<Float>(Float(transformDouble.columns.3.x), Float(transformDouble.columns.3.y), Float(transformDouble.columns.3.z), Float(transformDouble.columns.3.w))
        )

        // Extract CESIUM_RTC center (ECEF position for RTC-relative vertices)
        let rtcCenter: SIMD3<Double>?
        if let center = gltf.extensions?.CESIUM_RTC?.center, center.count >= 3 {
            rtcCenter = SIMD3<Double>(center[0], center[1], center[2])
        } else {
            rtcCenter = nil
        }

        return ParsedTile(
            meshDescriptors: meshDescriptors,
            textureImages: textureImages,
            transform: transform,
            transformDouble: transformDouble,
            rtcCenter: rtcCenter
        )
    }

    // MARK: - Transform Helpers

    /// Builds a 4x4 transform matrix from glTF TRS (Translation × Rotation × Scale).
    ///
    /// Per the glTF 2.0 spec, when a node has no `matrix` property, the transform
    /// is composed from `translation`, `rotation` (quaternion), and `scale`.
    private static func buildTRSTransform(
        translation: [Double]?,
        rotation: [Double]?,
        scale: [Double]?
    ) -> simd_double4x4 {
        let t = translation ?? [0, 0, 0]
        let r = rotation ?? [0, 0, 0, 1]
        let s = scale ?? [1, 1, 1]

        // Translation matrix
        var T = simd_double4x4(diagonal: .one)
        T.columns.3 = SIMD4<Double>(t[0], t[1], t[2], 1)

        // Rotation matrix from quaternion [x, y, z, w]
        let qx = r[0], qy = r[1], qz = r[2], qw = r[3]
        let x2 = qx + qx, y2 = qy + qy, z2 = qz + qz
        let xx = qx * x2, xy = qx * y2, xz = qx * z2
        let yy = qy * y2, yz = qy * z2, zz = qz * z2
        let wx = qw * x2, wy = qw * y2, wz = qw * z2

        let R = simd_double4x4(
            SIMD4<Double>(1 - (yy + zz), xy + wz, xz - wy, 0),
            SIMD4<Double>(xy - wz, 1 - (xx + zz), yz + wx, 0),
            SIMD4<Double>(xz + wy, yz - wx, 1 - (xx + yy), 0),
            SIMD4<Double>(0, 0, 0, 1)
        )

        // Scale matrix
        var S = simd_double4x4(diagonal: .one)
        S.columns.0.x = s[0]
        S.columns.1.y = s[1]
        S.columns.2.z = s[2]

        return T * R * S
    }

    /// Extracts `RTC_CENTER` from a b3dm feature table header.
    ///
    /// b3dm layout: `[28-byte header][Feature Table JSON][...]`
    /// The feature table JSON may contain `"RTC_CENTER": [x, y, z]` for
    /// relative-to-center positioning.
    private static func extractRTCCenterFromBatchedFormat(_ data: Data) -> SIMD3<Double>? {
        guard data.count >= 28 else { return nil }
        let featureTableJSONByteLength = Int(data.readUInt32(at: 12))
        guard featureTableJSONByteLength > 0,
              28 + featureTableJSONByteLength <= data.count else { return nil }

        let ftJSON = data[28..<(28 + featureTableJSONByteLength)]
        struct FeatureTable: Codable { let RTC_CENTER: [Double]? }  // swiftlint:disable:this nesting
        guard let ft = try? JSONDecoder().decode(FeatureTable.self, from: Data(ftJSON)),
              let center = ft.RTC_CENTER, center.count >= 3 else { return nil }
        return SIMD3<Double>(center[0], center[1], center[2])
    }

    // MARK: - Private Extraction

    private static func extractPrimitive(
        _ primitive: GLTFPrimitive,
        accessors: [GLTFAccessor],
        bufferViews: [GLTFBufferView],
        bin: Data,
        name: String
    ) throws -> MeshDescriptor? {
        guard let positionIndex = primitive.attributes["POSITION"],
              positionIndex < accessors.count else {
            return nil
        }

        let positions = try extractVec3(accessor: accessors[positionIndex], bufferViews: bufferViews, bin: bin)

        var descriptor = MeshDescriptor(name: name)
        descriptor.positions = MeshBuffers.Positions(positions)

        // Normals
        if let normalIndex = primitive.attributes["NORMAL"],
           normalIndex < accessors.count {
            let normals = try extractVec3(accessor: accessors[normalIndex], bufferViews: bufferViews, bin: bin)
            descriptor.normals = MeshBuffers.Normals(normals)
        }

        // Texture coordinates
        if let uvIndex = primitive.attributes["TEXCOORD_0"],
           uvIndex < accessors.count {
            // glTF puts the texture origin at the top-left and RealityKit at the bottom-left, so V
            // has to be flipped. Getting this wrong is not obviously wrong on a square texture —
            // the image is merely mirrored, and aerial imagery still reads as aerial imagery. It
            // shows up on the tiles Google pads to a taller power of two: their content sits at the
            // top with black filling the bottom, so an unflipped V samples the padding and the tile
            // renders as a solid black slab.
            let uvs = try extractVec2(accessor: accessors[uvIndex], bufferViews: bufferViews, bin: bin)
                .map { SIMD2<Float>($0.x, 1 - $0.y) }
            descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        }

        // Indices
        if let indicesIndex = primitive.indices, indicesIndex < accessors.count {
            let indices = try extractIndices(accessor: accessors[indicesIndex], bufferViews: bufferViews, bin: bin)
            descriptor.primitives = .triangles(indices)
        }

        return descriptor
    }

    private static func extractVec3(
        accessor: GLTFAccessor,
        bufferViews: [GLTFBufferView],
        bin: Data
    ) throws -> [SIMD3<Float>] {
        guard let viewIndex = accessor.bufferView, viewIndex < bufferViews.count else {
            throw DioramaError.glbParsingFailed(reason: "Invalid bufferView index")
        }
        let view = bufferViews[viewIndex]
        let byteOffset = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0)
        let count = accessor.count
        let stride = view.byteStride ?? 12 // 3 floats × 4 bytes

        var result: [SIMD3<Float>] = []
        result.reserveCapacity(count)

        for i in 0..<count {
            let offset = byteOffset + i * stride
            guard offset + 12 <= bin.count else { break }
            let x = bin.readFloat(at: offset)
            let y = bin.readFloat(at: offset + 4)
            let z = bin.readFloat(at: offset + 8)
            result.append(SIMD3<Float>(x, y, z))
        }

        return result
    }

    private static func extractVec2(
        accessor: GLTFAccessor,
        bufferViews: [GLTFBufferView],
        bin: Data
    ) throws -> [SIMD2<Float>] {
        guard let viewIndex = accessor.bufferView, viewIndex < bufferViews.count else {
            throw DioramaError.glbParsingFailed(reason: "Invalid bufferView index")
        }
        let view = bufferViews[viewIndex]
        let byteOffset = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0)
        let count = accessor.count
        let stride = view.byteStride ?? 8 // 2 floats × 4 bytes

        var result: [SIMD2<Float>] = []
        result.reserveCapacity(count)

        for i in 0..<count {
            let offset = byteOffset + i * stride
            guard offset + 8 <= bin.count else { break }
            let u = bin.readFloat(at: offset)
            let v = bin.readFloat(at: offset + 4)
            result.append(SIMD2<Float>(u, v))
        }

        return result
    }

    private static func extractIndices(
        accessor: GLTFAccessor,
        bufferViews: [GLTFBufferView],
        bin: Data
    ) throws -> [UInt32] {
        guard let viewIndex = accessor.bufferView, viewIndex < bufferViews.count else {
            throw DioramaError.glbParsingFailed(reason: "Invalid bufferView index")
        }
        let view = bufferViews[viewIndex]
        let byteOffset = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0)
        let count = accessor.count

        var result: [UInt32] = []
        result.reserveCapacity(count)

        // Component type: 5121 = UInt8, 5123 = UInt16, 5125 = UInt32
        switch accessor.componentType {
        case 5121: // UInt8
            for i in 0..<count {
                let offset = byteOffset + i
                guard offset < bin.count else { break }
                result.append(UInt32(bin[bin.startIndex.advanced(by: offset)]))
            }
        case 5123: // UInt16
            for i in 0..<count {
                let offset = byteOffset + i * 2
                guard offset + 2 <= bin.count else { break }
                result.append(UInt32(bin.readUInt16(at: offset)))
            }
        case 5125: // UInt32
            for i in 0..<count {
                let offset = byteOffset + i * 4
                guard offset + 4 <= bin.count else { break }
                result.append(bin.readUInt32(at: offset))
            }
        default:
            throw DioramaError.glbParsingFailed(reason: "Unsupported index component type: \(accessor.componentType)")
        }

        return result
    }

    private static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

// MARK: - glTF JSON Types (internal)

struct GLTFRoot: Codable {
    let asset: GLTFAsset
    let scenes: [GLTFScene]?
    let nodes: [GLTFNode]?
    let meshes: [GLTFMesh]?
    let accessors: [GLTFAccessor]?
    let bufferViews: [GLTFBufferView]?
    let materials: [GLTFMaterial]?
    let textures: [GLTFTexture]?
    let images: [GLTFImage]?
    let extensionsRequired: [String]?
    let extensions: GLTFExtensions?
}

/// Top-level glTF extensions.
struct GLTFExtensions: Codable {
    // swiftlint:disable:next identifier_name
    let CESIUM_RTC: CesiumRTCExtension?

    struct CesiumRTCExtension: Codable {
        let center: [Double]
    }
}

struct GLTFAsset: Codable {
    let version: String
    let generator: String?
}

struct GLTFScene: Codable {
    let nodes: [Int]?
}

struct GLTFNode: Codable {
    let mesh: Int?
    let matrix: [Double]?
    let translation: [Double]?
    let rotation: [Double]?  // quaternion [x, y, z, w]
    let scale: [Double]?
    let children: [Int]?
    let name: String?
}

struct GLTFMesh: Codable {
    let primitives: [GLTFPrimitive]
    let name: String?
}

struct GLTFPrimitive: Codable {
    let attributes: [String: Int]
    let indices: Int?
    let material: Int?
    let mode: Int?
}

struct GLTFAccessor: Codable {
    let bufferView: Int?
    let byteOffset: Int?
    let componentType: Int
    let count: Int
    let type: String
    let max: [Double]?
    let min: [Double]?
}

struct GLTFBufferView: Codable {
    let buffer: Int
    let byteOffset: Int?
    let byteLength: Int
    let byteStride: Int?
    let target: Int?
}

struct GLTFMaterial: Codable {
    let pbrMetallicRoughness: GLTFPBRMetallicRoughness?
    let name: String?
}

struct GLTFPBRMetallicRoughness: Codable {
    let baseColorTexture: GLTFTextureInfo?
    let metallicFactor: Double?
    let roughnessFactor: Double?
}

struct GLTFTextureInfo: Codable {
    let index: Int
    let texCoord: Int?
}

struct GLTFTexture: Codable {
    let source: Int?
    let sampler: Int?
}

struct GLTFImage: Codable {
    let bufferView: Int?
    let mimeType: String?
    let uri: String?
    let name: String?
}

// MARK: - Data Reading Helpers

/// Scalar reads for the GLB byte stream.
///
/// Every one of these goes through `loadUnaligned`, never `load`. glTF aligns its own offsets, but
/// that says nothing about where the buffer sits in memory: `load` traps unless the *address* is
/// aligned for the type, and the address is whatever the allocator handed the response — shifted
/// again for a b3dm, whose glTF body starts after variable-length feature and batch tables. The
/// resulting crash is a trap inside the standard library with the file's own bytes looking
/// perfectly valid, and it fires only on the tiles that happen to land at an odd address.
///
/// They are bounds-checked for the same reason. A truncated or empty response is a broken tile,
/// not a reason to take the app down.
extension Data {
    func readUInt32(at offset: Int) -> UInt32 {
        read(at: offset, as: UInt32.self)?.littleEndian ?? 0
    }

    func readUInt16(at offset: Int) -> UInt16 {
        read(at: offset, as: UInt16.self)?.littleEndian ?? 0
    }

    func readFloat(at offset: Int) -> Float {
        read(at: offset, as: Float.self) ?? 0
    }

    private func read<T>(at offset: Int, as type: T.Type) -> T? {
        guard offset >= 0, offset + MemoryLayout<T>.size <= count else { return nil }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: type) }
    }
}
