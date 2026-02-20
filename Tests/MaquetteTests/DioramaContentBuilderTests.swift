import CoreLocation
import Foundation
import Testing
@testable import Maquette

@Suite("Diorama Content Builder Tests")
struct DioramaContentBuilderTests {
    @Test("Builder collects markers and polylines")
    func collectsContent() {
        let group = buildContent {
            DioramaMarker(
                coordinate: CLLocationCoordinate2D(latitude: 36.0, longitude: -112.0),
                title: "A"
            )
            DioramaPolyline(
                coordinates: [
                    CLLocationCoordinate2D(latitude: 36.0, longitude: -112.0),
                    CLLocationCoordinate2D(latitude: 36.1, longitude: -112.1)
                ],
                id: "route"
            )
        }

        #expect(group.items.count == 2)

        if case .marker(let marker) = group.items[0] {
            #expect(marker.title == "A")
        } else {
            Issue.record("Expected marker at index 0")
        }

        if case .polyline(let polyline) = group.items[1] {
            #expect(polyline.id == "route")
            #expect(polyline.coordinates.count == 2)
        } else {
            Issue.record("Expected polyline at index 1")
        }
    }

    @Test("Conditional content with if/else works")
    func conditionalContent() {
        let showMarker = true
        let group = buildContent {
            if showMarker {
                DioramaMarker(
                    coordinate: CLLocationCoordinate2D(latitude: 36.0, longitude: -112.0),
                    title: "Visible"
                )
            }
        }

        #expect(group.items.count == 1)

        let hidden = false
        let group2 = buildContent {
            if hidden {
                DioramaMarker(
                    coordinate: CLLocationCoordinate2D(latitude: 36.0, longitude: -112.0),
                    title: "Hidden"
                )
            }
        }

        #expect(group2.items.count == 0)
    }

    @Test("If/else branches work correctly")
    func ifElseBranches() {
        let useMarker = true
        let group = buildContent {
            if useMarker {
                DioramaMarker(
                    coordinate: CLLocationCoordinate2D(latitude: 36.0, longitude: -112.0),
                    title: "Marker"
                )
            } else {
                DioramaPolyline(
                    coordinates: [
                        CLLocationCoordinate2D(latitude: 36.0, longitude: -112.0),
                        CLLocationCoordinate2D(latitude: 36.1, longitude: -112.1)
                    ]
                )
            }
        }

        #expect(group.items.count == 1)
        if case .marker = group.items[0] {
            // Expected
        } else {
            Issue.record("Expected marker from if branch")
        }
    }

    @Test("For loop with buildArray works")
    func forLoopContent() {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 36.0, longitude: -112.0),
            CLLocationCoordinate2D(latitude: 36.1, longitude: -112.1),
            CLLocationCoordinate2D(latitude: 36.2, longitude: -112.2)
        ]

        let group = buildContent {
            for (i, coord) in coordinates.enumerated() {
                DioramaMarker(coordinate: coord, title: "Pin \(i)")
            }
        }

        #expect(group.items.count == 3)
        for item in group.items {
            if case .marker = item {
                // Expected
            } else {
                Issue.record("Expected all items to be markers")
            }
        }
    }

    @Test("Empty builder produces empty items")
    func emptyBuilder() {
        let group = buildContent { }

        #expect(group.items.count == 0)
    }

    @Test("Mixed content types are preserved in order")
    func mixedContent() {
        let group = buildContent {
            DioramaMarker(
                coordinate: CLLocationCoordinate2D(latitude: 36.0, longitude: -112.0),
                title: "First"
            )
            DioramaPolyline(
                coordinates: [
                    CLLocationCoordinate2D(latitude: 36.0, longitude: -112.0),
                    CLLocationCoordinate2D(latitude: 36.1, longitude: -112.1)
                ]
            )
            DioramaMarker(
                coordinate: CLLocationCoordinate2D(latitude: 36.2, longitude: -112.2),
                title: "Third"
            )
        }

        #expect(group.items.count == 3)
        if case .marker = group.items[0] { } else { Issue.record("Expected marker at 0") }
        if case .polyline = group.items[1] { } else { Issue.record("Expected polyline at 1") }
        if case .marker = group.items[2] { } else { Issue.record("Expected marker at 2") }
    }

    // MARK: - Helper

    private func buildContent(
        @DioramaContentBuilder _ content: () -> DioramaContentGroup
    ) -> DioramaContentGroup {
        content()
    }
}
