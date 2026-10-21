import SwiftUI
import Testing
@testable import Maquette

@Suite("Native annotation identity and registry")
@MainActor
struct DioramaAnnotationRegistryTests {
    private let coordinate = Coordinate(latitude: 36, longitude: -112)

    private func declaration(_ title: String = "A", latitude: Double = 36) -> DioramaContentGroup {
        DioramaContentGroup {
            DioramaAnnotation(title, coordinate: Coordinate(latitude: latitude, longitude: -112)) { Text(title) }
        }
    }

    @Test("Anonymous declarations retain host lifetime across label, coordinate and style updates")
    func updates() throws {
        var resolver = DioramaContentIdentityResolver()
        let registry = DioramaAnnotationRegistry()
        let first = resolver.resolve(declaration())
        registry.reconcile(first)
        let record = try #require(registry.orderedRecords.first)
        let factory = record.factory.identity
        registry.updateMeasuredSize(CGSize(width: 80, height: 20), for: record.id)
        registry.reconcile(resolver.resolve(declaration("Changed", latitude: 37)))
        #expect(registry.orderedRecords.first === record)
        #expect(record.factory.identity != factory)
        #expect(record.descriptor?.title == "Changed")
        #expect(record.measuredSize == CGSize(width: 80, height: 20))
        _ = record.factory.makeView()
    }

    @Test("Identical anonymous siblings receive distinct renderer identities")
    func identicalSiblings() {
        let group = DioramaContentGroup {
            DioramaAnnotation("Same", coordinate: coordinate) { Text("Same") }
            DioramaAnnotation("Same", coordinate: coordinate) { Text("Same") }
        }
        var resolver = DioramaContentIdentityResolver()
        let registry = DioramaAnnotationRegistry()
        registry.reconcile(resolver.resolve(group))
        #expect(registry.records.count == 2)
        #expect(Set(registry.orderedRecords.map(\.id)).count == 2)
    }

    @Test("Conditional branches have independent lifetimes")
    func branches() throws {
        func content(_ flag: Bool) -> DioramaContentGroup {
            DioramaContentGroup {
                if flag {
                    DioramaAnnotation("Same", coordinate: coordinate) { Text("First") }
                } else {
                    DioramaAnnotation("Same", coordinate: coordinate) { Text("Second") }
                }
            }
        }
        var resolver = DioramaContentIdentityResolver()
        let registry = DioramaAnnotationRegistry()
        registry.reconcile(resolver.resolve(content(true)))
        let first = try #require(registry.orderedRecords.first)
        registry.reconcile(resolver.resolve(content(false)))
        let second = try #require(registry.orderedRecords.first)
        #expect(first.id != second.id)
        #expect(first.lifetimeID != second.lifetimeID)
    }

    @Test("Explicit identity survives coordinate updates, removal drops state, reinsertion starts fresh")
    func explicitIdentity() throws {
        func content(_ latitude: Double) -> DioramaContentGroup {
            DioramaContentGroup {
                DioramaAnnotation("A", coordinate: Coordinate(latitude: latitude, longitude: -112)) { Text("A") }
                    .id("summit").annotationPriority(9).opacity(0.4).tag("selection")
            }
        }
        var resolver = DioramaContentIdentityResolver()
        let registry = DioramaAnnotationRegistry()
        registry.reconcile(resolver.resolve(content(36)))
        let first = try #require(registry.records["summit"])
        registry.reconcile(resolver.resolve(content(37)))
        #expect(registry.records["summit"] === first)
        #expect(first.feature.style.opacity == 0.4)
        #expect(first.descriptor?.priority == 9)
        #expect(first.feature.selectionTag != nil)
        registry.reconcile(.empty)
        #expect(registry.records.isEmpty)
        registry.reconcile(resolver.resolve(content(37)))
        #expect(registry.records["summit"]?.lifetimeID != first.lifetimeID)
    }

    @Test("ForEach identity follows element IDs through reordering and coordinate changes")
    func collection() throws {
        func content(_ values: [Int], latitude: Double) -> DioramaContentGroup {
            DioramaContentGroup {
                ForEach(values, id: \.self) { value in
                    DioramaAnnotation("\(value)", coordinate: Coordinate(latitude: latitude, longitude: -112)) {
                        Text("\(value)")
                    }
                }
            }
        }
        var resolver = DioramaContentIdentityResolver()
        let registry = DioramaAnnotationRegistry()
        registry.reconcile(resolver.resolve(content([1, 2], latitude: 36)))
        let original = registry.orderedRecords
        registry.reconcile(resolver.resolve(content([2, 1], latitude: 37)))
        #expect(registry.orderedRecords[0] === original[1])
        #expect(registry.orderedRecords[1] === original[0])
        #expect(registry.orderedRecords[0].descriptor?.coordinate.latitude == 37)
    }

    @Test("Changing an explicit annotation ID inside a stable collection element starts a new lifetime")
    func explicitCollectionIdentity() throws {
        func content(_ identity: String) -> DioramaContentGroup {
            DioramaContentGroup {
                ForEach([1], id: \.self) { _ in
                    DioramaAnnotation("A", coordinate: coordinate) { Text("A") }
                        .id(identity)
                }
            }
        }
        var resolver = DioramaContentIdentityResolver()
        let registry = DioramaAnnotationRegistry()
        registry.reconcile(resolver.resolve(content("first")))
        let first = try #require(registry.orderedRecords.first)
        registry.reconcile(resolver.resolve(content("first")))
        #expect(registry.orderedRecords.first === first)
        registry.reconcile(resolver.resolve(content("second")))
        let second = try #require(registry.orderedRecords.first)
        #expect(second.id != first.id)
        #expect(second.lifetimeID != first.lifetimeID)
        #expect(second.feature.selectionAnnotationID == "second")
    }

    @Test("Invalid coordinates, styles and measurements cannot enter host layout")
    func invalidInputs() {
        let registry = DioramaAnnotationRegistry()
        registry.reconcile(DioramaContentGroup {
            DioramaAnnotation("Invalid", coordinate: Coordinate(latitude: .nan, longitude: 0)) { Text("A") }
            DioramaAnnotation("Invalid scale", coordinate: coordinate) { Text("B") }
                .annotationScale(metersPerPoint: -.infinity)
            DioramaAnnotation("Invalid priority", coordinate: coordinate) { Text("C") }
                .annotationPriority(.nan)
            DioramaAnnotation("Valid", coordinate: coordinate, id: "valid") { Text("D") }
        })
        #expect(registry.records.count == 1)
        registry.updateMeasuredSize(CGSize(width: CGFloat.nan, height: 10), for: "valid")
        #expect(registry.records["valid"]?.measuredSize == .zero)
    }

    @Test("Style wrappers preserve the actor-isolated factory and annotation options")
    func styles() throws {
        let primitive = DioramaAnnotation("A", coordinate: coordinate, anchor: .top) { Text("A") }
        let styled = primitive.tint(.orange).annotationOffset(x: 4, y: -8)
            .annotationOverlap(.allow).annotationOcclusion(.alwaysVisible)
            .annotationScale(metersPerPoint: 0.002).altitudeReference(.absolute)
        guard case .annotation(let feature) = try #require(styled.items.first) else {
            Issue.record("Expected annotation")
            return
        }
        #expect(feature.viewFactory === primitive.annotation.viewFactory)
        #expect(feature.viewAnnotation?.anchor == .top)
        #expect(feature.viewAnnotation?.offset == CGSize(width: 4, height: -8))
        #expect(feature.viewAnnotation?.overlap == .allow)
        #expect(feature.viewAnnotation?.occlusion == .alwaysVisible)
        #expect(feature.viewAnnotation?.metersPerPoint == 0.002)
        #expect(feature.style.altitude == .absolute)
    }
}
