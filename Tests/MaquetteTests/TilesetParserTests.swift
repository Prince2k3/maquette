import Foundation
import Testing
@testable import Maquette

@Suite("Tileset Parser Tests")
struct TilesetParserTests {

    @Test("Parse minimal tileset JSON")
    func parseMinimalTileset() throws {
        let json = """
        {
            "asset": { "version": "1.1" },
            "geometricError": 70.0,
            "root": {
                "boundingVolume": {
                    "region": [-1.3197, 0.6988, -1.3196, 0.6989, 0, 88]
                },
                "geometricError": 70.0
            }
        }
        """.data(using: .utf8)!

        let tileset = try JSONDecoder().decode(TilesetJSON.self, from: json)
        #expect(tileset.asset.version == "1.1")
        #expect(tileset.geometricError == 70.0)
        #expect(tileset.root.geometricError == 70.0)
        #expect(tileset.root.boundingVolume.region != nil)
        #expect(tileset.root.boundingVolume.region?.count == 6)
    }

    @Test("Parse tileset with children")
    func parseTilesetWithChildren() throws {
        let json = """
        {
            "asset": { "version": "1.1", "tilesetVersion": "2.0" },
            "geometricError": 240.0,
            "root": {
                "boundingVolume": {
                    "sphere": [0, 0, 0, 1000]
                },
                "geometricError": 240.0,
                "refine": "REPLACE",
                "content": { "uri": "root.glb" },
                "children": [
                    {
                        "boundingVolume": {
                            "sphere": [100, 0, 0, 500]
                        },
                        "geometricError": 120.0,
                        "content": { "uri": "child1.glb" }
                    },
                    {
                        "boundingVolume": {
                            "sphere": [-100, 0, 0, 500]
                        },
                        "geometricError": 120.0,
                        "content": { "uri": "child2.glb" }
                    }
                ]
            }
        }
        """.data(using: .utf8)!

        let tileset = try JSONDecoder().decode(TilesetJSON.self, from: json)
        #expect(tileset.asset.tilesetVersion == "2.0")
        #expect(tileset.root.refine == .replace)
        #expect(tileset.root.content?.uri == "root.glb")
        #expect(tileset.root.children?.count == 2)
        #expect(tileset.root.children?[0].content?.uri == "child1.glb")
    }

    @Test("Parse tileset with box bounding volume")
    func parseBoxBoundingVolume() throws {
        let json = """
        {
            "asset": { "version": "1.1" },
            "geometricError": 50.0,
            "root": {
                "boundingVolume": {
                    "box": [0, 0, 0, 100, 0, 0, 0, 100, 0, 0, 0, 100]
                },
                "geometricError": 50.0
            }
        }
        """.data(using: .utf8)!

        let tileset = try JSONDecoder().decode(TilesetJSON.self, from: json)
        #expect(tileset.root.boundingVolume.box?.count == 12)
        #expect(tileset.root.boundingVolume.region == nil)
        #expect(tileset.root.boundingVolume.sphere == nil)
    }

    @Test("Parse tileset with transform")
    func parseTilesetWithTransform() throws {
        let json = """
        {
            "asset": { "version": "1.1" },
            "geometricError": 100.0,
            "root": {
                "boundingVolume": {
                    "sphere": [0, 0, 0, 500]
                },
                "geometricError": 100.0,
                "transform": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 10, 20, 30, 1]
            }
        }
        """.data(using: .utf8)!

        let tileset = try JSONDecoder().decode(TilesetJSON.self, from: json)
        #expect(tileset.root.transform?.count == 16)
        #expect(tileset.root.transform?[12] == 10.0)
    }

    @Test("RefinementStrategy decoding")
    func refinementStrategy() throws {
        let addJSON = "\"ADD\"".data(using: .utf8)!
        let replaceJSON = "\"REPLACE\"".data(using: .utf8)!

        let add = try JSONDecoder().decode(RefinementStrategy.self, from: addJSON)
        let replace = try JSONDecoder().decode(RefinementStrategy.self, from: replaceJSON)

        #expect(add == .add)
        #expect(replace == .replace)
    }
}
