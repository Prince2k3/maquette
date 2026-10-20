import Foundation
import SwiftUI
import Testing
import simd
@testable import Maquette

struct DioramaCameraGeometryTests {
    @Test func cardinalBasisAndOverheadAreStable() {
        let north = DioramaCameraPose(heading: 0, pitch: 90, distance: 2, target: .zero)
        #expect(simd_length(north.forward - SIMD3(0, 0, -1)) < 0.00001)
        let east = DioramaCameraPose(heading: 90, pitch: 90, distance: 2, target: .zero)
        #expect(simd_length(east.forward - SIMD3(1, 0, 0)) < 0.00001)
        let overhead = DioramaCameraPose(heading: 0, pitch: 0, distance: 2, target: .zero)
        #expect(overhead.right == SIMD3(1, 0, 0))
        #expect(overhead.up == SIMD3(0, 0, -1))
        #expect(overhead.forward == SIMD3(0, -1, 0))
        let rotated = DioramaCameraPose(heading: 90, pitch: 0, distance: 2, target: .zero)
        #expect(simd_length(rotated.up - SIMD3(1, 0, 0)) < 0.00001)
    }

    @Test func fitsReliefBottomAndAsymmetricPadding() throws {
        let points: [SIMD3<Float>] = [-1, 1].flatMap { x in
            [-0.8, 2.5].flatMap { y in [-2, 2].map { z in SIMD3(Float(x), Float(y), Float(z)) } }
        }
        let padding = EdgeInsets(top: 71, leading: 93, bottom: 17, trailing: 9)
        for viewport in [CGSize(width: 260, height: 1100), CGSize(width: 1400, height: 240)] {
            let fitted = try #require(DioramaCameraGeometry.fit(
                points: points,
                pose: .init(heading: 37, pitch: 64, distance: 2, target: .zero),
                viewport: viewport, padding: padding,
                limits: DioramaCameraLimits(distance: 0.01...100)!))
            for point in points {
                let screen = try #require(DioramaCameraGeometry.projectedPoint(point, pose: fitted, viewport: viewport))
                #expect(screen.x >= padding.leading - 0.001)
                #expect(screen.x <= viewport.width - padding.trailing + 0.001)
                #expect(screen.y >= padding.top - 0.001)
                #expect(screen.y <= viewport.height - padding.bottom + 0.001)
            }
            #expect(fitted.target != SIMD3(0, 0.85, 0))
        }
    }

    @Test func impossibleLimitsAndInvalidInputsFail() {
        let pose = DioramaCameraPose(heading: 0, pitch: 0, distance: 1, target: .zero)
        let viewport = CGSize(width: 200, height: 200)
        let limits = DioramaCameraLimits(distance: 0.1...1)!
        #expect(DioramaCameraGeometry.fit(points: [SIMD3(-10, 0, -10), SIMD3(10, 0, 10)], pose: pose,
            viewport: viewport, padding: .init(), limits: limits) == nil)
        let invalidPoints: [[SIMD3<Float>]] = [[], [SIMD3(.nan, 0, 0)]]
        for points in invalidPoints {
            #expect(DioramaCameraGeometry.fit(points: points, pose: pose,
                viewport: viewport, padding: .init(), limits: limits) == nil)
        }
        #expect(DioramaCameraGeometry.fit(points: [.zero], pose: pose,
            viewport: viewport, padding: .init(top: 200, leading: 0, bottom: 0, trailing: 0), limits: limits) == nil)
        #expect(DioramaCameraGeometry.projectedPoint(pose.position, pose: pose, viewport: viewport) == nil)
    }

    @Test func fitEnforcesPitchAndMinimumDistance() throws {
        let fitted = try #require(DioramaCameraGeometry.fit(points: [.zero],
            pose: .init(heading: -90, pitch: 90, distance: 1, target: .zero),
            viewport: CGSize(width: 400, height: 300), padding: .init(),
            limits: DioramaCameraLimits(distance: 3...5, pitchDegrees: 10...45)!))
        #expect(fitted.pitch == 45)
        #expect(fitted.heading == 270)
        #expect((3...5).contains(fitted.distance))
    }

    @Test func enormousDistanceCeilingStillFindsSceneScaleFit() throws {
        let fitted = try #require(DioramaCameraGeometry.fit(
            points: [SIMD3(-1, -1, -1), SIMD3(1, 1, 1)],
            pose: .init(heading: 0, pitch: 0, distance: 1, target: .zero),
            viewport: CGSize(width: 400, height: 400), padding: .init(),
            limits: DioramaCameraLimits(distance: 0.01...Float.greatestFiniteMagnitude)!))
        #expect(fitted.distance > 2.7)
        #expect(fitted.distance < 2.8)
    }

    @Test func sparseDiagonalInputFitsEveryImpliedBoundsCorner() throws {
        let viewport = CGSize(width: 400, height: 300)
        let padding = EdgeInsets(top: 31, leading: 47, bottom: 13, trailing: 19)
        let fitted = try #require(DioramaCameraGeometry.fit(
            points: [SIMD3(-1, -2, -3), SIMD3(1, 2, 3)],
            pose: .init(heading: 43, pitch: 61, distance: 1, target: .zero),
            viewport: viewport, padding: padding,
            limits: DioramaCameraLimits(distance: 0.01...100)!))
        for x: Float in [-1, 1] {
            for y: Float in [-2, 2] {
                for z: Float in [-3, 3] {
                    let screen = try #require(DioramaCameraGeometry.projectedPoint(
                        SIMD3(x, y, z), pose: fitted, viewport: viewport))
                    #expect(screen.x >= padding.leading - 0.001)
                    #expect(screen.x <= viewport.width - padding.trailing + 0.001)
                    #expect(screen.y >= padding.top - 0.001)
                    #expect(screen.y <= viewport.height - padding.bottom + 0.001)
                }
            }
        }
    }

    @Test func interpolationUsesElapsedFractionAndShortestHeadingArc() {
        let start = DioramaCameraPose(heading: 359, pitch: 0, distance: 1, target: .zero)
        let end = DioramaCameraPose(heading: 1, pitch: 80, distance: 5, target: SIMD3(2, 4, 6))
        #expect(DioramaCameraGeometry.interpolate(from: start, to: end, progress: 0) == start)
        #expect(DioramaCameraGeometry.interpolate(from: start, to: end, progress: 1) == end)
        let middle = DioramaCameraGeometry.interpolate(from: start, to: end, progress: 0.5)
        #expect(middle.heading == 0)
        #expect(middle.pitch == 40)
        #expect(middle.distance == 3)
        #expect(middle.target == SIMD3(1, 2, 3))
        let quarter = DioramaCameraGeometry.interpolate(from: start, to: end, progress: 0.25)
        #expect(quarter.heading == 359.3125)
        #expect(quarter.pitch == 12.5)
        #expect(quarter.distance == 1.625)
        #expect(DioramaCameraGeometry.normalizedHeading(-1) == 359)
    }
    @Test func containmentRejectsConcaveCrossingsWithInsideVertices() {
        let outline: [SIMD2<Float>] = [.init(-2, -2), .init(2, -2), .init(2, 2), .init(0.5, 2),
            .init(0.5, 0), .init(-0.5, 0), .init(-0.5, 2), .init(-2, 2)]
        #expect(!DioramaCameraGeometry.contains([.init(-1, 1), .init(1, 1)], boundary: outline, closed: false))
        #expect(!DioramaCameraGeometry.contains([.init(-1, -1), .init(1, -1), .init(1, 1), .init(-1, 1)], boundary: outline, closed: true))
        #expect(DioramaCameraGeometry.contains([.init(-1, -1), .init(1, -1)], boundary: outline, closed: false))
    }

}
