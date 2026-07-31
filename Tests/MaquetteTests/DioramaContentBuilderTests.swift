import CoreLocation
import Foundation
import Testing
@testable import Maquette

@Suite("Diorama Content Builder Tests")
struct DioramaContentBuilderTests {
    private static let a = CLLocationCoordinate2D(latitude: 36.0, longitude: -112.0)
    private static let b = CLLocationCoordinate2D(latitude: 36.1, longitude: -112.1)
    private static let c = CLLocationCoordinate2D(latitude: 36.2, longitude: -112.2)

    /// The geometry an item drew, so a test can say what it expected rather than pattern-matching
    /// a nested enum three levels deep at every assertion.
    private func geometry(of item: DioramaContentItem) -> Geometry? {
        guard case .annotation(let annotation) = item else { return nil }
        return annotation.feature.geometry
    }

    @Test("Builder collects annotations")
    func collectsContent() throws {
        let group = buildContent {
            DioramaMarker("A", coordinate: Self.a, id: "A")
            DioramaPolyline(coordinates: [Self.a, Self.b], id: "route")
        }

        #expect(group.items.count == 2)

        let pin = try #require(group.items.first)
        guard case .annotation(let marker) = pin, case .point(let point)? = marker.feature.geometry
        else {
            Issue.record("Expected a point annotation at index 0")
            return
        }
        #expect(marker.id == "A")
        #expect(abs(point.coordinate.latitude - 36.0) < 1e-9)

        guard case .annotation(let line) = group.items[1],
              case .lineString(let string)? = line.feature.geometry
        else {
            Issue.record("Expected a line annotation at index 1")
            return
        }
        #expect(line.id == "route")
        #expect(string.coordinates.count == 2)
    }

    @Test("An annotation takes the feature's own identity")
    func identityComesFromTheFeature() {
        // GeoJSON carries identity, and content re-applied after a pan has to replace the entity it
        // made last time rather than adding a second one beside it.
        let feature = Feature.point(Coordinate(Self.a), id: .string("summit"))
        #expect(DioramaAnnotation(feature).id == "summit")
        #expect(DioramaAnnotation(feature, id: "override").id == "override")

        let numbered = Feature.point(Coordinate(Self.a), id: .number(42))
        #expect(DioramaAnnotation(numbered).id == "42.0")

        // No identity in the data gets a *stable* digest, so declaring the same content twice
        // produces the same identity — which is what lets a re-applied group diff as unchanged
        // instead of tearing every entity down. The old rule was a fresh UUID per init.
        let anonymous = Feature.point(Coordinate(Self.a))
        #expect(!DioramaAnnotation(anonymous).id.isEmpty)
        #expect(DioramaAnnotation(anonymous).id == DioramaAnnotation(anonymous).id)
        let other = Feature.point(Coordinate(Self.b))
        #expect(DioramaAnnotation(anonymous).id != DioramaAnnotation(other).id)
    }

    @Test("A decoded feature collection is content on its own")
    func featureCollectionIsContent() throws {
        let json = """
        {
          "type": "FeatureCollection",
          "features": [
            {
              "type": "Feature",
              "id": "trailhead",
              "geometry": {"type": "Point", "coordinates": [-112.0, 36.0]},
              "properties": {"name": "South Kaibab"}
            },
            {
              "type": "Feature",
              "geometry": {
                "type": "LineString",
                "coordinates": [[-112.0, 36.0], [-112.1, 36.1]]
              },
              "properties": null
            }
          ]
        }
        """
        let collection = try JSONDecoder().decode(
            FeatureCollection.self,
            from: Data(json.utf8)
        )
        let group = buildContent { collection }

        #expect(group.items.count == 2)
        guard case .point = try #require(geometry(of: group.items[0])) else {
            Issue.record("Expected the first feature to stay a point")
            return
        }
        guard case .lineString = try #require(geometry(of: group.items[1])) else {
            Issue.record("Expected the second feature to stay a line")
            return
        }
        guard case .annotation(let first) = group.items[0] else { return }
        #expect(first.id == "trailhead")
        #expect(first.feature[property: "name"] == .string("South Kaibab"))
    }

    @Test("Conditional content with if/else works")
    func conditionalContent() {
        let showMarker = true
        let group = buildContent {
            if showMarker {
                DioramaMarker("Visible", coordinate: Self.a)
            }
        }

        #expect(group.items.count == 1)

        let hidden = false
        let group2 = buildContent {
            if hidden {
                DioramaMarker("Hidden", coordinate: Self.a)
            }
        }

        #expect(group2.items.count == 0)
    }

    @Test("If/else branches work correctly")
    func ifElseBranches() throws {
        let useMarker = true
        let group = buildContent {
            if useMarker {
                DioramaMarker("Marker", coordinate: Self.a)
            } else {
                DioramaPolyline(coordinates: [Self.a, Self.b])
            }
        }

        #expect(group.items.count == 1)
        guard case .point = try #require(geometry(of: group.items[0])) else {
            Issue.record("Expected a point from the if branch")
            return
        }
    }

    @Test("For loop with buildArray works")
    func forLoopContent() {
        let coordinates = [Self.a, Self.b, Self.c]

        let group = buildContent {
            for (index, coordinate) in coordinates.enumerated() {
                DioramaMarker("Pin \(index)", coordinate: coordinate)
            }
        }

        #expect(group.items.count == 3)
        for item in group.items {
            guard case .point? = geometry(of: item) else {
                Issue.record("Expected every item to be a point")
                return
            }
        }
    }

    @Test("Empty builder produces empty items")
    func emptyBuilder() {
        let group = buildContent { }

        #expect(group.items.count == 0)
    }

    @Test("Mixed content types are preserved in order")
    func mixedContent() throws {
        let group = buildContent {
            DioramaMarker("First", coordinate: Self.a)
            DioramaPolyline(coordinates: [Self.a, Self.b])
            DioramaMarker("Third", coordinate: Self.c)
        }

        #expect(group.items.count == 3)
        guard case .point = try #require(geometry(of: group.items[0])),
              case .lineString = try #require(geometry(of: group.items[1])),
              case .point = try #require(geometry(of: group.items[2]))
        else {
            Issue.record("Expected point, line, point in that order")
            return
        }
    }

    @Test("The style says what an altitude means")
    func styleCarriesTheAltitudeReference() {
        // The feature carries a number and the style says how to read it — which is the whole
        // reason altitude lives on the style rather than being inferred from the geometry.
        #expect(DioramaMarker(coordinate: Self.a).annotation.style.altitude == .clampToGround)
        #expect(
            DioramaMarker(coordinate: Self.a, altitude: .relativeToGround)
                .annotation.style.altitude == .relativeToGround
        )
        #expect(DioramaPolyline(coordinates: [Self.a, Self.b], lineWidth: 0.01)
            .annotation.style.lineWidth == 0.01)
    }

    // MARK: - Helper

    private func buildContent(
        @DioramaContentBuilder _ content: () -> DioramaContentGroup
    ) -> DioramaContentGroup {
        content()
    }
}
