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

    @Test("Parse minimal GLB with one triangle")
    func parseMinimalGLB() throws {
        let glb = buildMinimalGLB()
        let parsed = try GLBParser.parse(glb)

        #expect(parsed.meshDescriptors.count == 1)
        #expect(parsed.textureImages.isEmpty)
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
