import Foundation
import RealityKit
import simd

/// Stitches adjacent terrain tile meshes at their edges to eliminate visible seams.
public enum MeshStitcher {
    /// Aligns edge vertices between adjacent terrain meshes so their positions match exactly.
    ///
    /// This operates on raw vertex arrays before mesh generation. Adjacent tiles share
    /// the same edge vertex positions to prevent gaps or Z-fighting at seams.
    ///
    /// - Parameters:
    ///   - grids: Elevation grids for all tiles.
    ///   - tilePositions: Tile x/y coordinates corresponding to each grid.
    ///   - resolution: The grid resolution being used for mesh generation.
    /// - Returns: The modified grids with stitched edge values.
    public static func stitchEdges(
        grids: [ElevationGrid],
        tilePositions: [(x: Int, y: Int)],
        resolution: Int
    ) -> [ElevationGrid] {
        guard grids.count > 1 else { return grids }

        var mutableValues: [[Float]] = grids.map { $0.values }
        let width = grids[0].width
        let height = grids[0].height

        for i in 0..<grids.count {
            let tileA = tilePositions[i]

            for j in (i + 1)..<grids.count {
                let tileB = tilePositions[j]

                // Horizontal neighbor (B is to the right of A)
                if tileB.x == tileA.x + 1 && tileB.y == tileA.y {
                    for row in 0..<height {
                        let rightEdgeA = row * width + (width - 1)
                        let leftEdgeB = row * width
                        let avg = (mutableValues[i][rightEdgeA] + mutableValues[j][leftEdgeB]) / 2.0
                        mutableValues[i][rightEdgeA] = avg
                        mutableValues[j][leftEdgeB] = avg
                    }
                }

                // Vertical neighbor (B is below A)
                if tileB.y == tileA.y + 1 && tileB.x == tileA.x {
                    for col in 0..<width {
                        let bottomEdgeA = (height - 1) * width + col
                        let topEdgeB = col
                        let avg = (mutableValues[i][bottomEdgeA] + mutableValues[j][topEdgeB]) / 2.0
                        mutableValues[i][bottomEdgeA] = avg
                        mutableValues[j][topEdgeB] = avg
                    }
                }
            }
        }

        return zip(grids, mutableValues).map { grid, values in
            ElevationGrid(width: grid.width, height: grid.height, values: values)
        }
    }
}
