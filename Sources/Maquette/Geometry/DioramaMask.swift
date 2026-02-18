import Foundation
import RealityKit
import SwiftUI
import simd

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Generates the diorama boundary mask, pedestal rim, and base plate geometry.
public enum DioramaMask {
    /// Generates the complete mask entity containing boundary, pedestal, and base.
    ///
    /// - Parameters:
    ///   - shape: The shape of the diorama boundary.
    ///   - physicalDiameter: Physical diameter in meters.
    ///   - baseColor: Color for the pedestal rim.
    /// - Returns: An `Entity` containing the mask geometry.
    @MainActor
    public static func generateMaskEntity(
        shape: DioramaShape,
        physicalDiameter: Float,
        baseColor: SwiftUI.Color
    ) throws -> Entity {
        let maskEntity = Entity()
        maskEntity.name = "DioramaMask"

        // Pedestal rim
        let rimEntity = try generatePedestalRim(
            shape: shape,
            diameter: physicalDiameter,
            baseColor: baseColor
        )
        maskEntity.addChild(rimEntity)

        // Base plate
        let baseEntity = try generateBasePlate(
            shape: shape,
            diameter: physicalDiameter
        )
        maskEntity.addChild(baseEntity)

        return maskEntity
    }

    // MARK: - Pedestal Rim

    @MainActor
    private static func generatePedestalRim(
        shape: DioramaShape,
        diameter: Float,
        baseColor: SwiftUI.Color
    ) throws -> ModelEntity {
        let rimHeight: Float = 0.02
        let rimThickness: Float = 0.015
        let radius = diameter / 2.0

        let mesh: MeshResource
        switch shape {
        case .circular:
            mesh = try generateRingMesh(
                outerRadius: radius + rimThickness,
                innerRadius: radius,
                height: rimHeight,
                segments: 64
            )
        case .rectangular(let width, let depth):
            mesh = try generateRectangularRimMesh(
                width: width + rimThickness * 2,
                depth: depth + rimThickness * 2,
                innerWidth: width,
                innerDepth: depth,
                height: rimHeight
            )
        }

        var material = UnlitMaterial()
        #if canImport(UIKit)
        material.color.tint = UIColor(baseColor)
        #elseif canImport(AppKit)
        material.color.tint = NSColor(baseColor)
        #endif

        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "PedestalRim"
        entity.position.y = -rimHeight / 2.0
        return entity
    }

    // MARK: - Base Plate

    @MainActor
    private static func generateBasePlate(
        shape: DioramaShape,
        diameter: Float
    ) throws -> ModelEntity {
        let mesh: MeshResource
        switch shape {
        case .circular:
            mesh = .generateCylinder(height: 0.005, radius: diameter / 2.0)
        case .rectangular(let width, let depth):
            mesh = .generateBox(width: width, height: 0.005, depth: depth)
        }

        var material = UnlitMaterial()
        #if canImport(UIKit)
        material.color.tint = UIColor(white: 0.15, alpha: 1.0)
        #elseif canImport(AppKit)
        material.color.tint = NSColor(white: 0.15, alpha: 1.0)
        #endif

        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "BasePlate"
        let rimHeight: Float = 0.02
        let plateHeight: Float = 0.005
        entity.position.y = -(rimHeight + plateHeight / 2.0)
        return entity
    }

    // MARK: - Ring Mesh Generation

    @MainActor
    private static func generateRingMesh(
        outerRadius: Float,
        innerRadius: Float,
        height: Float,
        segments: Int
    ) throws -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        let halfHeight = height / 2.0

        for i in 0...segments {
            let angle = Float(i) / Float(segments) * 2.0 * .pi
            let cosA = cos(angle)
            let sinA = sin(angle)
            let u = Float(i) / Float(segments)

            // Outer top
            positions.append(SIMD3<Float>(outerRadius * cosA, halfHeight, outerRadius * sinA))
            normals.append(SIMD3<Float>(cosA, 0, sinA))
            uvs.append(SIMD2<Float>(u, 1))

            // Outer bottom
            positions.append(SIMD3<Float>(outerRadius * cosA, -halfHeight, outerRadius * sinA))
            normals.append(SIMD3<Float>(cosA, 0, sinA))
            uvs.append(SIMD2<Float>(u, 0))

            // Inner top
            positions.append(SIMD3<Float>(innerRadius * cosA, halfHeight, innerRadius * sinA))
            normals.append(SIMD3<Float>(0, 1, 0))
            uvs.append(SIMD2<Float>(u, 1))

            // Inner bottom
            positions.append(SIMD3<Float>(innerRadius * cosA, -halfHeight, innerRadius * sinA))
            normals.append(SIMD3<Float>(-cosA, 0, -sinA))
            uvs.append(SIMD2<Float>(u, 0))
        }

        for i in 0..<segments {
            let base = UInt32(i * 4)
            let next = UInt32((i + 1) * 4)

            // Outer wall
            indices.append(contentsOf: [base, base + 1, next])
            indices.append(contentsOf: [next, base + 1, next + 1])

            // Top face
            indices.append(contentsOf: [base, next, base + 2])
            indices.append(contentsOf: [base + 2, next, next + 2])

            // Inner wall
            indices.append(contentsOf: [base + 2, next + 2, base + 3])
            indices.append(contentsOf: [base + 3, next + 2, next + 3])

            // Bottom face
            indices.append(contentsOf: [base + 1, base + 3, next + 1])
            indices.append(contentsOf: [next + 1, base + 3, next + 3])
        }

        var descriptor = MeshDescriptor(name: "pedestalRim")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)

        return try MeshResource.generate(from: [descriptor])
    }

    // MARK: - Rectangular Rim (simplified as a box frame)

    @MainActor
    private static func generateRectangularRimMesh(
        width: Float,
        depth: Float,
        innerWidth: Float,
        innerDepth: Float,
        height: Float
    ) throws -> MeshResource {
        // Use a simple box as a placeholder for the rectangular rim
        // A proper implementation would generate a hollow rectangular frame
        return .generateBox(width: width, height: height, depth: depth)
    }
}
