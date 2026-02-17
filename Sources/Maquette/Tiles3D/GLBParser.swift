import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import RealityKit
import simd

/// Parses a GLB (glTF Binary) file into RealityKit mesh and material data.
public struct GLBParser: Sendable {

    /// Parse result containing mesh geometry and texture data.
    public struct ParsedTile: @unchecked Sendable {
        /// Mesh descriptors for each primitive in the GLB.
        public let meshDescriptors: [MeshDescriptor]
        /// Texture images extracted from the GLB.
        public let textureImages: [CGImage]
        /// Transform matrix from the root node (identity if none specified).
        public let transform: simd_float4x4
    }

    // MARK: - GLB Constants

    private static let glbMagic: UInt32 = 0x46546C67  // "glTF"
    private static let jsonChunkType: UInt32 = 0x4E4F534A  // "JSON"
    private static let binChunkType: UInt32 = 0x004E4942   // "BIN\0"

    // MARK: - Public API

    /// Parses a GLB binary blob into mesh + texture data.
    /// - Parameter data: Raw GLB file data.
    /// - Returns: Parsed tile with mesh descriptors and textures.
    /// - Throws: `DioramaError.glbParsingFailed` or `DioramaError.unsupportedTileFormat` for Draco.
    public static func parse(_ data: Data) throws -> ParsedTile {
        guard data.count >= 12 else {
            throw DioramaError.glbParsingFailed(reason: "Data too small for GLB header")
        }

        // Read header
        let magic = data.readUInt32(at: 0)
        let version = data.readUInt32(at: 4)

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

        // Extract root transform
        let transform: simd_float4x4
        if let scenes = gltf.scenes, let scene = scenes.first,
           let nodes = scene.nodes, let firstNodeIndex = nodes.first,
           let allNodes = gltf.nodes, firstNodeIndex < allNodes.count,
           let matrix = allNodes[firstNodeIndex].matrix, matrix.count == 16 {
            transform = simd_float4x4(
                SIMD4<Float>(Float(matrix[0]), Float(matrix[1]), Float(matrix[2]), Float(matrix[3])),
                SIMD4<Float>(Float(matrix[4]), Float(matrix[5]), Float(matrix[6]), Float(matrix[7])),
                SIMD4<Float>(Float(matrix[8]), Float(matrix[9]), Float(matrix[10]), Float(matrix[11])),
                SIMD4<Float>(Float(matrix[12]), Float(matrix[13]), Float(matrix[14]), Float(matrix[15]))
            )
        } else {
            transform = .init(diagonal: .one)
        }

        return ParsedTile(
            meshDescriptors: meshDescriptors,
            textureImages: textureImages,
            transform: transform
        )
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
            let uvs = try extractVec2(accessor: accessors[uvIndex], bufferViews: bufferViews, bin: bin)
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

extension Data {
    func readUInt32(at offset: Int) -> UInt32 {
        withUnsafeBytes { buffer in
            buffer.load(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }

    func readUInt16(at offset: Int) -> UInt16 {
        withUnsafeBytes { buffer in
            buffer.load(fromByteOffset: offset, as: UInt16.self).littleEndian
        }
    }

    func readFloat(at offset: Int) -> Float {
        withUnsafeBytes { buffer in
            buffer.load(fromByteOffset: offset, as: Float.self)
        }
    }
}
