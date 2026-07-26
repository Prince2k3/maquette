import Foundation
import Testing
import simd
@testable import Maquette

/// `BoundaryPrism.contains` short-circuits through an inscribed and a circumscribed circle so the
/// exact crossing-number walk runs only in the annulus between them. That optimisation is only
/// worth having if it is indistinguishable from the exact test, so these check agreement rather
/// than any particular internal structure.
@Suite("Boundary Prism Containment Tests")
struct BoundaryPrismContainmentTests {
    /// Samples a grid covering the outline and its surroundings, asserting the prism and the
    /// boundary agree on every point.
    private func expectAgreement(
        _ boundary: DioramaBoundary,
        scale: Float,
        extent: Float,
        steps: Int = 120,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let prism = BoundaryPrism(boundary: boundary, scale: scale)
        // The prism scales the outline into the geometry's space, so compare against an outline
        // scaled the same way rather than the original.
        let scaled = DioramaBoundary(vertices: boundary.vertices.map { $0 / scale })

        var disagreements = 0
        for i in 0...steps {
            for j in 0...steps {
                let point = SIMD2<Float>(
                    -extent + 2 * extent * Float(i) / Float(steps),
                    -extent + 2 * extent * Float(j) / Float(steps)
                )
                if prism.contains(point) != scaled.contains(point) {
                    disagreements += 1
                }
            }
        }
        #expect(disagreements == 0, "prism disagreed with the exact test at \(disagreements) points",
                sourceLocation: sourceLocation)
    }

    @Test("A circular outline agrees with the exact test everywhere")
    func circularAgrees() {
        expectAgreement(DioramaBoundary.make(shape: .circular, extent: SIMD2(0.8, 0.8)), scale: 1, extent: 0.6)
    }

    @Test("The scaled prism used by the 3D Tiles path agrees with the exact test")
    func scaledAgrees() {
        // The scale the photorealistic path actually uses: 0.8 m of diorama across 1,400 m of ground.
        let scale: Float = 0.8 / 1400
        expectAgreement(DioramaBoundary.make(shape: .circular, extent: SIMD2(0.8, 0.8)), scale: scale, extent: 0.6 / scale)
    }

    @Test("A hexagonal outline agrees with the exact test everywhere")
    func hexagonalAgrees() {
        expectAgreement(DioramaBoundary.make(shape: .hexagonal, extent: SIMD2(0.8, 0.8)), scale: 1, extent: 0.6)
    }

    @Test("A rounded rectangle agrees with the exact test everywhere")
    func roundedRectangleAgrees() {
        let shape = DioramaShape.roundedRectangular(width: 0.9, depth: 0.65, cornerRadius: 0.12)
        expectAgreement(DioramaBoundary.make(shape: shape, extent: SIMD2(0.9, 0.65)), scale: 1, extent: 0.7)
    }

    /// A concave outline can place its centroid outside itself, which is the case the inscribed
    /// circle cannot be used for. The star is the shape that actually does it.
    @Test("A concave star outline agrees with the exact test everywhere")
    func concaveStarAgrees() {
        let points: [SIMD2<Float>] = (0..<10).map { index in
            let radius: Float = index.isMultiple(of: 2) ? 0.45 : 0.19
            let angle = Float(index) / 10 * 2 * .pi - .pi / 2
            return SIMD2(radius * cos(angle), radius * sin(angle))
        }
        expectAgreement(DioramaBoundary.make(shape: .custom(points: points), extent: SIMD2(0.9, 0.9)), scale: 1, extent: 0.6)
    }

    /// A crescent: the centroid falls in the bite taken out of it, outside the outline entirely.
    @Test("An outline whose centroid lies outside it agrees with the exact test")
    func centroidOutsideAgrees() {
        var points: [SIMD2<Float>] = []
        for i in 0...32 {
            let angle = -.pi / 2 + Float(i) / 32 * .pi
            points.append(SIMD2(0.4 * cos(angle), 0.4 * sin(angle)))
        }
        for i in 0...32 {
            let angle = .pi / 2 - Float(i) / 32 * .pi
            points.append(SIMD2(0.32 * cos(angle) - 0.12, 0.32 * sin(angle)))
        }
        expectAgreement(DioramaBoundary.make(shape: .custom(points: points), extent: SIMD2(0.8, 0.8)), scale: 1, extent: 0.6)
    }
}
