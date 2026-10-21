import simd
import Testing
@testable import Maquette

@Suite("Fixed-storage triangle clipping")
struct OverlayTriangleIntersectionTests {
    @Test func edgeClassificationPreservesReferenceGeometryAndAttributes() throws {
        let clips: [[SIMD2<Double>]] = [
            [.init(0, 0), .init(1, 0), .init(0, 1)],
            [.init(0, 0), .init(0, 1), .init(1, 0)],
            [.init(0, 0), .init(1, 0), .init(1, 1), .init(0, 1)],
            [.init(0, 0), .init(0, 1), .init(1, 1), .init(1, 0)]
        ]
        func vertex(_ p: SIMD2<Double>) -> OverlayVertex {
            .init(point: p, uv: .init(p.x * 2 + p.y, p.y * 3 - p.x), altitude: p.x + p.y * 4)
        }
        for clip in clips {
            for x in -4...8 {
                for y in -4...8 {
                    let origin = SIMD2(Double(x) / 8, Double(y) / 8)
                    let source = OverlayTriangle(a: vertex(origin), b: vertex(origin + .init(0.4, 0.1)),
                                                 c: vertex(origin + .init(0.05, 0.35)))
                    for constant in [false, true] {
                        let attributes = constant ? OverlayTriangle(
                            a: .init(point: source.a.point, uv: .init(0.25, 0.75), altitude: 17),
                            b: .init(point: source.b.point, uv: .init(0.25, 0.75), altitude: 17),
                            c: .init(point: source.c.point, uv: .init(0.25, 0.75), altitude: 17)) : source
                        var work = try OverlayWork(.init()), referenceWork = try OverlayWork(.init())
                        let result = try OverlayTriangleIntersection.clip(attributes, a: clip[0], b: clip[1], c: clip[2],
                            d: clip.count == 4 ? clip[3] : nil, epsilon: 1e-10, work: &work)
                        let expected = try OverlayAreaGeometry.intersect(attributes, with: clip, epsilon: 1e-10, work: &referenceWork)
                        let actual = (0..<result.count).map { result[$0] }
                        #expect(abs(OverlayMath.area(actual) - OverlayMath.area(expected)) < 1e-9)
                        for point in actual {
                            if constant {
                                #expect(point.uv == .init(0.25, 0.75) && point.altitude == 17)
                            } else {
                                #expect(abs(point.uv.x - (point.point.x * 2 + point.point.y)) < 1e-9)
                                #expect(abs(point.uv.y - (point.point.y * 3 - point.point.x)) < 1e-9)
                                #expect(abs(point.altitude - (point.point.x + point.point.y * 4)) < 1e-9)
                            }
                            #expect(expected.contains { simd_distance($0.point, point.point) < 1e-9 })
                        }
                    }
                }
            }
        }
    }

    @Test func constantAndVariableAttributesKeepTheSameWorkBudget() throws {
        for constant in [false, true] {
            let source = OverlayTriangle(a: .init(point: .init(0.1, 0.1)),
                b: .init(point: .init(0.3, 0.1), uv: constant ? .zero : .init(1, 0)),
                c: .init(point: .init(0.1, 0.3)))
            var insufficient = try OverlayWork(.init(maxOperations: 8))
            #expect(throws: OverlayGeometryError.budgetExceeded) {
                try OverlayTriangleIntersection.clip(source, a: .init(0, 0), b: .init(1, 0), c: .init(0, 1),
                    epsilon: 1e-10, work: &insufficient)
            }
            var exact = try OverlayWork(.init(maxOperations: 9))
            let result = try OverlayTriangleIntersection.clip(source, a: .init(0, 0), b: .init(1, 0), c: .init(0, 1),
                epsilon: 1e-10, work: &exact)
            #expect(result.count == 3)
        }
    }

}
