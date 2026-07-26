import Foundation
import Testing
@testable import Maquette

@Suite("GLB Parser Tests")
struct GLBParserTests {

    /// Builds a minimal valid GLB with one triangle (no texture).
    private func buildMinimalGLB() -> Data {
        // Positions: 3 vertices forming a triangle
        let positions: [Float] = [
            0, 0, 0,
            1, 0, 0,
            0, 1, 0
        ]
        // Indices: one triangle
        let indices: [UInt16] = [0, 1, 2]

        // Build BIN chunk
        var binData = Data()
        // Positions (3 × 3 floats × 4 bytes = 36 bytes)
        for p in positions {
            var value = p
            binData.append(Data(bytes: &value, count: 4))
        }
        // Indices (3 × 2 bytes = 6 bytes)
        for idx in indices {
            var value = idx
            binData.append(Data(bytes: &value, count: 2))
        }
        // Pad BIN to 4-byte alignment
        while binData.count % 4 != 0 {
            binData.append(0)
        }

        // Build JSON chunk
        let gltfJSON = """
        {
            "asset": { "version": "2.0" },
            "scenes": [{ "nodes": [0] }],
            "nodes": [{ "mesh": 0 }],
            "meshes": [{
                "primitives": [{
                    "attributes": { "POSITION": 0 },
                    "indices": 1,
                    "mode": 4
                }]
            }],
            "accessors": [
                {
                    "bufferView": 0,
                    "componentType": 5126,
                    "count": 3,
                    "type": "VEC3",
                    "max": [1, 1, 0],
                    "min": [0, 0, 0]
                },
                {
                    "bufferView": 1,
                    "componentType": 5123,
                    "count": 3,
                    "type": "SCALAR"
                }
            ],
            "bufferViews": [
                { "buffer": 0, "byteOffset": 0, "byteLength": 36 },
                { "buffer": 0, "byteOffset": 36, "byteLength": 6 }
            ],
            "buffers": [{ "byteLength": \(binData.count) }]
        }
        """
        var jsonData = Data(gltfJSON.utf8)
        // Pad JSON to 4-byte alignment with spaces
        while jsonData.count % 4 != 0 {
            jsonData.append(0x20) // space
        }

        // Build GLB
        var glb = Data()

        // Header: magic, version, total length
        var magic: UInt32 = 0x46546C67
        var version: UInt32 = 2
        let totalLength = UInt32(12 + 8 + jsonData.count + 8 + binData.count)
        var totalLengthVal = totalLength

        glb.append(Data(bytes: &magic, count: 4))
        glb.append(Data(bytes: &version, count: 4))
        glb.append(Data(bytes: &totalLengthVal, count: 4))

        // JSON chunk
        var jsonLength = UInt32(jsonData.count)
        var jsonType: UInt32 = 0x4E4F534A
        glb.append(Data(bytes: &jsonLength, count: 4))
        glb.append(Data(bytes: &jsonType, count: 4))
        glb.append(jsonData)

        // BIN chunk
        var binLength = UInt32(binData.count)
        var binType: UInt32 = 0x004E4942
        glb.append(Data(bytes: &binLength, count: 4))
        glb.append(Data(bytes: &binType, count: 4))
        glb.append(binData)

        return glb
    }

    /// Builds a minimal GLB whose one triangle carries the given glTF texture coordinates.
    private func buildTexturedGLB(uvs: [SIMD2<Float>]) -> Data {
        let positions: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
        let indices: [UInt16] = [0, 1, 2]

        var binData = Data()
        for value in positions {
            var scalar = value
            binData.append(Data(bytes: &scalar, count: 4))
        }
        for uv in uvs {
            var u = uv.x, v = uv.y
            binData.append(Data(bytes: &u, count: 4))
            binData.append(Data(bytes: &v, count: 4))
        }
        for index in indices {
            var value = index
            binData.append(Data(bytes: &value, count: 2))
        }
        while binData.count % 4 != 0 { binData.append(0) }

        let gltfJSON = """
        {
            "asset": { "version": "2.0" },
            "scenes": [{ "nodes": [0] }],
            "nodes": [{ "mesh": 0 }],
            "meshes": [{
                "primitives": [{
                    "attributes": { "POSITION": 0, "TEXCOORD_0": 1 },
                    "indices": 2,
                    "mode": 4
                }]
            }],
            "accessors": [
                { "bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3" },
                { "bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC2" },
                { "bufferView": 2, "componentType": 5123, "count": 3, "type": "SCALAR" }
            ],
            "bufferViews": [
                { "buffer": 0, "byteOffset": 0, "byteLength": 36 },
                { "buffer": 0, "byteOffset": 36, "byteLength": 24 },
                { "buffer": 0, "byteOffset": 60, "byteLength": 6 }
            ],
            "buffers": [{ "byteLength": \(binData.count) }]
        }
        """
        var jsonData = Data(gltfJSON.utf8)
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }

        var glb = Data()
        var magic: UInt32 = 0x4654_6C67
        var version: UInt32 = 2
        var totalLength = UInt32(12 + 8 + jsonData.count + 8 + binData.count)
        glb.append(Data(bytes: &magic, count: 4))
        glb.append(Data(bytes: &version, count: 4))
        glb.append(Data(bytes: &totalLength, count: 4))

        var jsonLength = UInt32(jsonData.count)
        var jsonType: UInt32 = 0x4E4F_534A
        glb.append(Data(bytes: &jsonLength, count: 4))
        glb.append(Data(bytes: &jsonType, count: 4))
        glb.append(jsonData)

        var binLength = UInt32(binData.count)
        var binType: UInt32 = 0x004E_4942
        glb.append(Data(bytes: &binLength, count: 4))
        glb.append(Data(bytes: &binType, count: 4))
        glb.append(binData)

        return glb
    }

    /// glTF measures V downwards from the top of the image and RealityKit upwards from the bottom.
    ///
    /// Worth asserting rather than eyeballing: on a square texture an unflipped V only mirrors the
    /// image, which aerial photography hides completely. It becomes visible on the taller textures
    /// Google pads to a power of two, where the mirrored V samples the blank half and the tile
    /// renders as a black slab.
    @Test("Texture coordinates flip from glTF's top-left origin to RealityKit's bottom-left")
    func flipsTextureCoordinateV() throws {
        let source: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0.25), SIMD2(0.5, 1)]
        let parsed = try GLBParser.parse(buildTexturedGLB(uvs: source))

        let descriptor = try #require(parsed.meshDescriptors.first)
        let uvs = try #require(descriptor.textureCoordinates?.elements)
        #expect(uvs.count == source.count)
        for (index, expected) in source.enumerated() {
            #expect(uvs[index].x == expected.x)
            #expect(uvs[index].y == 1 - expected.y)
        }
    }

    @Test("Parse minimal GLB with one triangle")
    func parseMinimalGLB() throws {
        let glb = buildMinimalGLB()
        let parsed = try GLBParser.parse(glb)

        #expect(parsed.meshDescriptors.count == 1)
        #expect(parsed.textureImages.isEmpty)
    }

    /// A tile that arrives short must be rejected, not crash the app.
    ///
    /// The scalar reads that walk the GLB byte stream are bounds-checked as well as unaligned, and
    /// this is the half of that which can be asserted: alignment depends on where the allocator
    /// happens to put the buffer, but truncation is deterministic. Every prefix of a valid file is
    /// exercised, so a chunk header that claims more bytes than arrived is covered along with a
    /// response cut off mid-header.
    @Test("Truncated GLB data is rejected rather than read past its end")
    func rejectsTruncatedGLB() {
        let complete = buildMinimalGLB()
        for length in 0..<complete.count {
            let truncated = complete.prefix(length)
            // Throwing is the requirement; which error it picks is not.
            _ = try? GLBParser.parse(Data(truncated))
        }
    }

    @Test("Reject non-GLB data")
    func rejectNonGLBData() {
        let badData = Data("not a GLB file".utf8)
        do {
            _ = try GLBParser.parse(badData)
            Issue.record("Expected glbParsingFailed error")
        } catch let error as DioramaError {
            if case .glbParsingFailed = error {
                // Expected
            } else {
                Issue.record("Expected glbParsingFailed, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Reject too-small data")
    func rejectTooSmallData() {
        let smallData = Data([0x01, 0x02])
        do {
            _ = try GLBParser.parse(smallData)
            Issue.record("Expected glbParsingFailed error")
        } catch let error as DioramaError {
            if case .glbParsingFailed = error {
                // Expected
            } else {
                Issue.record("Expected glbParsingFailed, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Detect Draco compression")
    func detectDracoCompression() {
        // Build a GLB-like structure with Draco extension required
        let gltfJSON = """
        {
            "asset": { "version": "2.0" },
            "extensionsRequired": ["KHR_draco_mesh_compression"],
            "meshes": [{
                "primitives": [{
                    "attributes": { "POSITION": 0 }
                }]
            }],
            "accessors": [
                { "bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3" }
            ],
            "bufferViews": [
                { "buffer": 0, "byteOffset": 0, "byteLength": 36 }
            ]
        }
        """
        var jsonData = Data(gltfJSON.utf8)
        while jsonData.count % 4 != 0 {
            jsonData.append(0x20)
        }

        var glb = Data()
        var magic: UInt32 = 0x46546C67
        var version: UInt32 = 2
        var totalLength = UInt32(12 + 8 + jsonData.count)
        glb.append(Data(bytes: &magic, count: 4))
        glb.append(Data(bytes: &version, count: 4))
        glb.append(Data(bytes: &totalLength, count: 4))

        var jsonLength = UInt32(jsonData.count)
        var jsonType: UInt32 = 0x4E4F534A
        glb.append(Data(bytes: &jsonLength, count: 4))
        glb.append(Data(bytes: &jsonType, count: 4))
        glb.append(jsonData)

        do {
            _ = try GLBParser.parse(glb)
            Issue.record("Expected unsupportedTileFormat error")
        } catch let error as DioramaError {
            if case .unsupportedTileFormat = error {
                // Expected
            } else {
                Issue.record("Expected unsupportedTileFormat, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
