import CoreGraphics
@testable import MaquetteNext
import SwiftUI
import Testing

@Suite("Next content resolution and isolation")
@MainActor
struct ResolutionTests {
    private let point = MaquetteNext.Coordinate(latitude: 36, longitude: -112)

    @Test func polygonHolesAndMultipartDataSurviveResolution() throws {
        let outer = LinearRing([point, .init(latitude: 37, longitude: -112),
                                .init(latitude: 37, longitude: -111), .init(latitude: 36, longitude: -111)])
        let hole = LinearRing([.init(latitude: 36.2, longitude: -111.8), .init(latitude: 36.4, longitude: -111.8),
                               .init(latitude: 36.3, longitude: -111.6)])
        let polygon = Polygon(exterior: outer, holes: [hole])
        let feature = Feature(geometry: .multiPolygon(MultiPolygon([polygon])), id: .string("park"))
        let content = DioramaContentGroup { DioramaFeature(feature) }
        let descriptor = try #require(resolve(content).entries.first?.descriptor)
        #expect(descriptor.geometry == .feature(feature))
        func transfer<T: Sendable>(_ value: T) {}
        transfer(descriptor)
    }

    @Test func fillAndStrokeAreIndependentAndLatestLocalStrokeWins() throws {
        let a = resolve(DioramaCircle(center: point, radius: 500)
            .fill(.green).stroke(.blue, width: .geographicMeters(10))
            .stroke(.orange, width: .physicalMeters(0.003)))
        let b = resolve(DioramaCircle(center: point, radius: 500)
            .stroke(.orange, width: .physicalMeters(0.003)).fill(.green))
        #expect(a.entries.first?.descriptor.style == b.entries.first?.descriptor.style)
        #expect(a.entries.first?.descriptor.style.stroke == .orange)
    }

    @Test func childStyleOverridesInheritedDefaultsRegardlessOfModifierOrder() {
        let content = DioramaContentGroup {
            DioramaMarker(coordinate: point).tint(.orange)
            DioramaMarker(coordinate: point)
        }.tint(.blue)
        let entries = resolve(content).entries
        #expect(entries[0].descriptor.style.tint == .orange)
        #expect(entries[1].descriptor.style.tint == .blue)
    }

    private struct Place: Identifiable { let id: Int; let coordinate: MaquetteNext.Coordinate }
    private func labels(_ places: [Place], title: String = "Label") -> ResolvedContent {
        resolve(DioramaContentGroup {
            ForEach(places) { place in
                DioramaAnnotation(title, coordinate: place.coordinate) { Text(title) }.tag(place.id)
            }
        })
    }

    @Test func collectionReorderAndCoordinateEditsKeepAnnotationLifetimes() throws {
        let registry = AnnotationRegistry()
        registry.reconcile(labels([Place(id: 1, coordinate: point), Place(id: 2, coordinate: point)]))
        let lifetimes = registry.records.mapValues(\.lifetimeID)
        registry.reconcile(labels([Place(id: 2, coordinate: .init(latitude: 37, longitude: -110)),
                                   Place(id: 1, coordinate: point)], title: "Updated"))
        #expect(registry.records.mapValues(\.lifetimeID) == lifetimes)
        #expect(registry.records.values.allSatisfy {
            if case .annotation(let title, _, _) = $0.descriptor.geometry { return title == "Updated" }
            return false
        })
        registry.reconcile(labels([Place(id: 1, coordinate: point)]))
        #expect(registry.records.count == 1)
        registry.reconcile(labels([Place(id: 2, coordinate: point), Place(id: 1, coordinate: point)]))
        let restored = try #require(registry.records.first { $0.value.descriptor.tag == TypedValue(2) })
        #expect(restored.value.lifetimeID != lifetimes[restored.key])
    }

    @Test func identicalLabelsInDifferentStatementsHaveDistinctKeys() {
        let registry = AnnotationRegistry()
        registry.reconcile(resolve(DioramaContentGroup {
            DioramaAnnotation("Same", coordinate: point) { Text("Same") }
            DioramaAnnotation("Same", coordinate: point) { Text("Same") }
        }))
        #expect(registry.records.count == 2)
        #expect(Set(registry.records.values.map(\.lifetimeID)).count == 2)
    }

    @Test func conditionalBranchesDoNotReuseEachOthersViewStateKeys() {
        func content(_ first: Bool) -> ResolvedContent {
            resolve(DioramaContentGroup {
                if first {
                    DioramaAnnotation("First", coordinate: point) { Text("First") }
                } else {
                    DioramaAnnotation("Second", coordinate: point) { Text("Second") }
                }
                DioramaAnnotation("Unchanged sibling", coordinate: point) { Text("Sibling") }
            })
        }
        let first = content(true).entries, second = content(false).entries
        #expect(first[0].descriptor.key != second[0].descriptor.key)
        #expect(first[1].descriptor.key == second[1].descriptor.key)
    }

    @Test func imageRevisionChangesResourceWithoutChangingContentIdentity() throws {
        let pixels = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        func descriptor(_ revision: String) throws -> ContentDescriptor {
            try #require(resolve(DioramaContentGroup {
                DioramaImageOverlay(
                    image: .init(id: "survey", revision: revision, image: pixels),
                    bounds: .init(west: 179, south: 0, east: -179, north: 1)
                ).opacity(0.6).id("survey-overlay")
            }).entries.first?.descriptor)
        }
        let first = try descriptor("1"), next = try descriptor("2")
        #expect(first.key == next.key)
        #expect(first.geometry != next.geometry)
        #expect(next.style.opacity == 0.6)
    }

    @Test func typedSelectionRejectsDifferentTypesAndHostsAreIndependent() {
        var first: Int? = 1
        var second: Int? = 2
        let a = SelectionBinding(Binding(get: { first }, set: { first = $0 }))
        let b = SelectionBinding(Binding(get: { second }, set: { second = $0 }))
        a.write(TypedValue(3.0))
        #expect(first == 1)
        a.write(TypedValue(3))
        #expect(first == 3)
        #expect(b.read() == TypedValue(2))
        a.write(nil)
        #expect(first == nil)
        #expect(second == 2)
    }

    @Test func annotationFactoriesStayLazyAndUpdateWithoutReplacingLifetime() throws {
        let registry = AnnotationRegistry()
        var invocations = 0
        func content(_ count: Int) -> ResolvedContent {
            resolve(DioramaAnnotation("Label", coordinate: point) {
                invocations += count
                return Text("\(count)")
            }.id("label"))
        }
        registry.reconcile(content(1))
        #expect(invocations == 0)
        let old = try #require(registry.records.values.first)
        _ = old.makeView()
        registry.reconcile(content(2))
        let new = try #require(registry.records.values.first)
        #expect(old.lifetimeID == new.lifetimeID)
        _ = new.makeView()
        #expect(invocations == 3)
    }
}
