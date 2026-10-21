import CoreLocation
import CoreGraphics
import Maquette
import SwiftUI

/// A named diorama, chosen to exercise a specific part of the library.
struct DemoPreset: Identifiable {
    let id: String
    let title: String
    /// What this preset is meant to demonstrate.
    let caption: String
    let region: DioramaRegion
    var shape: DioramaShape = .circular
    var physicalSize: Float = 0.8
    /// The substrate: what is fetched and how the solid is built.
    var style: DioramaStyle = .standard
    /// The visual treatment laid over the built chunk. An effect is a restyle rather than a
    /// different substrate, which is why it sits beside the style rather than inside it.
    var effect: DioramaEffect = .none
    /// Where the orbit camera starts for this preset.
    var camera = DioramaCamera(heading: .zero, pitch: .radians(.pi / 2 - 0.45), distance: 1.3)
}

enum DemoPresets {
    /// Every preset, in picker order.
    ///
    /// The outline preset decodes a bundled document, so it is dropped rather than faked when the
    /// file is missing — a demo that silently substituted a circle would be showing the one thing
    /// the preset exists to disprove.
    static let all: [DemoPreset] = fixed + [outline].compactMap { $0 }

    /// A chunk cut to a real-world boundary, framed by the boundary itself.
    ///
    /// Nothing here says where Yosemite is or how much ground to fetch: the ring does, through
    /// `DioramaRegion(fitting:)` and `DioramaShape.geoJSON(_:)`. That is the whole difference from
    /// the Star preset, which cuts an equally arbitrary shape but in diorama metres about the
    /// origin — this one is in longitude and latitude, so it lands on the ground it names, at true
    /// scale, wherever that happens to be relative to the chunk's middle.
    ///
    /// The valley is a good test of the clip as well as the frame: it is long, it bends, and the
    /// bend puts a reflex vertex on the south side, so a chunk that came back convex would be
    /// visibly wrong rather than subtly so.
    private static let outline: DemoPreset? = {
        guard let url = Bundle.main.url(forResource: "yosemite-valley", withExtension: "geojson"),
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(FeatureCollection.self, from: data),
              let region = DioramaRegion(fitting: document),
              let shape = DioramaShape.geoJSON(document)
        else { return nil }

        return DemoPreset(
            id: "outline",
            title: "Outline",
            caption: "Yosemite Valley, cut to a GeoJSON boundary",
            region: region,
            shape: shape,
            style: .standard(exaggeration: 1.6, chunk: .alpine),
            // A ribbon eleven kilometres long and four wide, so the standard framing crops the
            // ends off it. Pull back until the whole outline is in the frame, and look down
            // further than the other presets — the silhouette is what this one is about.
            camera: DioramaCamera(pitch: .radians(.pi / 2 - (0.95)), distance: 1.55)
        )
    }()

    private static let grandCanyon = CLLocationCoordinate2D(latitude: 36.0544, longitude: -112.1401)
    private static let rainier = CLLocationCoordinate2D(latitude: 46.8523, longitude: -121.7603)
    private static let sanFrancisco = CLLocationCoordinate2D(latitude: 37.7929, longitude: -122.3971)

    private static let fixed: [DemoPreset] = [
        DemoPreset(
            id: "canyon",
            title: "Canyon",
            caption: "Circular chunk, canyon strata walls",
            region: DioramaRegion(center: grandCanyon, radius: 6000),
            style: .standard(exaggeration: 1.6, chunk: .canyon)
        ),

        DemoPreset(
            id: "camera",
            title: "Camera",
            caption: "3D camera controls · North cyan · East orange · South pink · West green",
            region: DioramaRegion(center: grandCanyon, radius: 1000),
            shape: .rectangular(width: 0.8, depth: 0.8),
            style: .standard(exaggeration: 1.6, chunk: .canyon),
            camera: DioramaCamera(heading: .zero, pitch: .degrees(50), distance: 1.6)
        ),

        DemoPreset(
            id: "inputs", title: "Inputs", caption: "Two focused scenes inside a scrolling page",
            region: DioramaRegion(center: grandCanyon, radius: 1000),
            style: .standard(exaggeration: 1.6, chunk: .canyon, panRange: 0.8),
            camera: DioramaCamera(pitch: .degrees(50), distance: 1.6)
        ),
        DemoPreset(
            id: "hexagon",
            title: "Hexagon",
            caption: "Hexagonal outline, alpine strata",
            region: DioramaRegion(center: rainier, radius: 9000),
            shape: .hexagonal,
            style: .standard(exaggeration: 1.6, chunk: .alpine)
        ),

        DemoPreset(
            id: "plinth",
            title: "Plinth",
            caption: "Rounded rectangle on a plinth",
            region: DioramaRegion(
                center: CLLocationCoordinate2D(latitude: 37.7460, longitude: -119.5332),
                radius: 5000
            ),
            shape: .roundedRectangular(width: 0.9, depth: 0.65, cornerRadius: 0.12),
            physicalSize: 0.9,
            style: .standard(
                exaggeration: 1.6,
                chunk: TerrainChunkStyle(
                    baseDepth: .proportional(0.2),
                    wall: .strata(.earth),
                    base: .plinth(color: Color(white: 0.1), height: 0.03, inset: -0.025)
                )
            ),
            // Wider than the other presets, so pull back to keep it in frame.
            camera: DioramaCamera(pitch: .radians(.pi / 2 - (0.45)), distance: 1.7)
        ),

        DemoPreset(
            id: "star",
            title: "Star",
            caption: "Arbitrary concave outline",
            region: DioramaRegion(
                center: CLLocationCoordinate2D(latitude: 37.2692, longitude: -112.9466),
                radius: 4000
            ),
            // A five-pointed star, to prove arbitrary outlines clip correctly.
            shape: .custom(points: (0..<10).map { index in
                let radius: Float = index.isMultiple(of: 2) ? 0.45 : 0.19
                let angle = Float(index) / 10 * 2 * .pi - .pi / 2
                return SIMD2(radius * cos(angle), radius * sin(angle))
            }),
            style: .standard(
                exaggeration: 1.6,
                chunk: TerrainChunkStyle(baseDepth: .proportional(0.16), wall: .strata(.canyon))
            )
        ),

        DemoPreset(
            id: "surface",
            title: "Surface",
            caption: "No earth beneath — surface only",
            region: DioramaRegion(center: grandCanyon, radius: 6000),
            style: .standard(exaggeration: 1.6, chunk: .surfaceOnly)
        ),

        // Photogrammetry cut to the outline, resting on a tray. Straight to Google rather than
        // proxied through Cesium ion. Google bills only the root tileset request, and the provider
        // caches that, so relaunching the demo does not keep costing events.
        //
        // The radius is what makes or breaks this path. Level of detail is chosen from the model's
        // on-screen size, so a wide region is a small region: ten kilometres of city squeezed into
        // a chunk the size of a dinner plate leaves a building two pixels tall, and the tileset
        // correctly refuses to refine past flat draped imagery. Roughly a kilometre is where
        // facades start reading as facades.
        DemoPreset(
            id: "photoreal",
            title: "City",
            caption: "San Francisco downtown, cut to the outline",
            region: DioramaRegion(center: sanFrancisco, radius: 700),
            style: .photorealistic(
                provider: GoogleTiles3DProvider(apiKey: Secrets.googleMapsAPIKey),
                style: .detailed
            )
        ),

        // Half Dome, the end of the trail out of Yosemite Valley. Natural terrain rather than
        // buildings, and 1,400 m of relief inside the outline — the case where a flat-looking
        // model is unmistakably wrong. The summit and the valley floor have to be in frame
        // together; that contrast is the whole point of the preset.
        DemoPreset(
            id: "photoreal-trail",
            title: "Trail",
            caption: "Half Dome, Yosemite — photoreal terrain",
            region: DioramaRegion(
                center: CLLocationCoordinate2D(latitude: 37.7459, longitude: -119.5332),
                radius: 1400
            ),
            style: .photorealistic(
                provider: GoogleTiles3DProvider(apiKey: Secrets.googleMapsAPIKey),
                style: .detailed
            ),
            camera: DioramaCamera(pitch: .radians(.pi / 2 - (0.28)), distance: 1.7)
        ),

        // Fetches a region 80% wider than the chunk, so the first drag is served without a fetch.
        // Dragging past that rolls new tiles in rather than stopping, so the Grand Canyon is only
        // where this one starts.
        DemoPreset(
            id: "pan",
            title: "Pan",
            caption: "One finger slides terrain, two orbit",
            region: DioramaRegion(center: grandCanyon, radius: 5000),
            style: .standard(exaggeration: 1.6, chunk: .canyon, panRange: 0.8)
        ),

        // The same gesture over streamed photogrammetry. `panRange` widens what the tile traversal
        // keeps rather than what is fetched up front — the ground outside the outline is streamed
        // and cut away, and sliding the outline onto it is what brings it back.
        DemoPreset(
            id: "photoreal-pan",
            title: "Pan 3D",
            caption: "Slide the outline across San Francisco",
            region: DioramaRegion(center: sanFrancisco, radius: 700),
            style: .photorealistic(
                provider: GoogleTiles3DProvider(apiKey: Secrets.googleMapsAPIKey),
                style: .detailed,
                panRange: 0.6
            )
        ),

        // Deliberately the same ground as the Pan preset, and pannable, because the effect has to
        // survive a pan: contours are re-traced from the chunk's re-sampled triangles on every
        // step, and a roll hands the chunk a fresh surface material underneath them.
        DemoPreset(
            id: "hologram",
            title: "Hologram",
            caption: "Projected contours over the Grand Canyon",
            region: DioramaRegion(center: grandCanyon, radius: 6000),
            style: .standard(exaggeration: 1.6, chunk: .canyon, panRange: 0.8),
            effect: .hologram
        ),

        // The reason this preset is a small radius over a dense downtown: OSM footprints are the
        // only thing standing on the chunk here, since both elevation providers are bare-earth and
        // a heightfield could not hold a vertical wall anyway. Anywhere without tall buildings,
        // the layer is invisible and the preset proves nothing.
        //
        // Buildings are exaggerated past the terrain's own scale for the same reason terrain is
        // exaggerated past reality: at 800 m to the chunk's 0.8 m, a fifteen-metre block is 7 mm
        // tall and reads as texture. The towers carry the effect; the blocks around them are what
        // make it a city.
        DemoPreset(
            id: "buildings",
            title: "City grid",
            caption: "OSM buildings extruded over San Francisco",
            region: DioramaRegion(center: sanFrancisco, radius: 800),
            style: .standard(
                exaggeration: 1.6,
                chunk: .canyon,
                buildings: BuildingStyle(exaggeration: 1.5),
                panRange: 0.8
            ),
            effect: .hologram
        ),

        // Terrain with real structure in it, because the ink is drawn from the chunk's own
        // triangles: the rim comes from where the surface ends and everything inside it comes from
        // where two triangles disagree about which way they face. Somewhere flat draws an outline
        // around a blank card and proves nothing about the effect.
        DemoPreset(
            id: "ink",
            title: "Ink",
            caption: "The Grand Canyon drawn as an illustration",
            region: DioramaRegion(center: grandCanyon, radius: 6000),
            style: .standard(exaggeration: 1.6, chunk: .canyon, panRange: 0.8),
            effect: .ink
        ),

        // A cone, and deliberately not the canyon the ink preset uses. `.automatic` spreads its
        // bands evenly across the chunk's whole relief, so terrain that is mostly plateau under
        // one outlying ridge terraces into a single sheet of card. A stratovolcano puts ground at
        // every height between its base and its summit, so every rung gets used.
        DemoPreset(
            id: "terraced",
            title: "Terraced",
            caption: "Mount Rainier, painted from its own imagery",
            region: DioramaRegion(center: rainier, radius: 9000),
            style: .standard(exaggeration: 1.6, chunk: .canyon, panRange: 0.8),
            effect: .terraced
        ),

        // The same effect, unmodified, over ground of a completely different colour — which is the
        // whole point of measuring the palette rather than authoring it. Centred on the river
        // rather than on the rim, which is the difference between a ladder that gets used and one
        // that does not.
        DemoPreset(
            id: "terraced-desert",
            title: "Terraced desert",
            caption: "The Grand Canyon cut on the same ladder, in its own colours",
            region: DioramaRegion(
                center: CLLocationCoordinate2D(latitude: 36.1000, longitude: -112.1000),
                radius: 9000
            ),
            style: .standard(
                exaggeration: 1.4,
                chunk: TerrainChunkStyle(
                    baseDepth: .proportional(0.18),
                    wall: .strata(.earth),
                    // The plinth is what makes it read as a model of somewhere rather than a
                    // piece of it.
                    base: .plinth(color: Color(white: 0.35), height: 0.03, inset: -0.02)
                ),
                panRange: 0.8
            ),
            effect: .terraced
        ),
    ]
}

struct ContentView: View {
    /// Whether this instance is the volumetric window rather than the plain one.
    ///
    /// Only the plain window offers the button that opens the volume; offering it from inside the
    /// volume would hand back a second copy of the window the user is already standing at.
    var isVolume = false

    @State private var selection = DemoPresets.all.firstIndex {
        $0.id == ProcessInfo.processInfo.environment["MAQUETTE_PRESET"]
    } ?? 0

    private static var initialPreset: DemoPreset {
        DemoPresets.all.first {
            $0.id == ProcessInfo.processInfo.environment["MAQUETTE_PRESET"]
        } ?? DemoPresets.all[0]
    }

    /// Geographic navigation has its own binding, separate from the orbit camera.
    @State private var groundPosition = DioramaGroundPosition(region: Self.initialPreset.region)

    @State private var buildingsVisible = true

    /// The orbit camera, seeded from the preset and thereafter the user's.
    @State private var position: DioramaCameraPosition = .automatic

    private enum Place: Hashable, Sendable { case yavapaiPoint, surveyArea, observationRadius, cameraLabel }

    /// Application selection is independent of the marker's rendering identity.
    @State private var selectedAnnotation: Place?
    @State private var annotationMoved = false

    /// Whether the diorama is placed on a real surface through the camera (iOS only).
    @State private var arActive = false

    #if os(visionOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    private var preset: DemoPreset { DemoPresets.all[selection] }

    /// The preset's style with the live buildings toggle folded in.
    ///
    /// Visibility is normalized out of the substrate comparison inside the library, so flipping it
    /// hides the buildings in place rather than refetching the chunk.
    private var style: DioramaStyle {
        guard preset.id == "buildings" else { return preset.style }
        var buildingStyle = BuildingStyle(exaggeration: 1.5)
        buildingStyle.isVisible = buildingsVisible
        return .standard(
            exaggeration: 1.6,
            chunk: .canyon,
            buildings: buildingStyle,
            panRange: 0.8
        )
    }

    var body: some View {
        #if os(visionOS)
        // The diorama takes the whole window and the controls float beside it in an ornament,
        // which is the platform's own answer to "chrome around a scene": no backdrop competing
        // with the room behind the glass, no forced colour scheme, and nothing stacked on top of
        // the RealityView squeezing the thing the demo exists to show.
        diorama
            .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
                controlBar
            }
        #else
        ZStack {
            Color(white: 0.08).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                diorama
                if preset.id == "buildings" {
                    buildingsToggle
                }
                presetPicker
            }
        }
        .preferredColorScheme(.dark)
        #endif
    }

    @ViewBuilder private var diorama: some View {
        #if os(visionOS)
        terrainDiorama
        #else
        if preset.id == "inputs" { InputLabView(region: preset.region) }
        else { terrainDiorama }
        #endif
    }

    private var terrainDiorama: some View {
        DioramaView(
            groundPosition: $groundPosition,
            shape: preset.shape,
            physicalSize: preset.physicalSize,
            cameraPosition: $position,
            selection: $selectedAnnotation
        ) {
            if ["photoreal", "photoreal-trail", "photoreal-pan"].contains(preset.id) {
                photorealPlacementContent
            }
            if preset.id == "camera" {
                DioramaAnnotation("Camera viewpoint", coordinate: Turf.destination(from: preset.region.center, meters: annotationMoved ? 250 : 0, bearing: 0), id: "camera-viewpoint") {
                    StatefulAnnotationCard(selected: selectedAnnotation == .cameraLabel)
                }
                .annotationOffset(y: -12)
                .annotationPriority(10)
                .tint(annotationMoved ? .orange : .cyan)
                .annotationOcclusion(.alwaysVisible)
                .tag(Place.cameraLabel)
                DioramaAnnotation("Terrain anchor", coordinate: Turf.destination(from: preset.region.center, meters: 300, bearing: 180), id: "terrain-anchor") {
                    Text("Terrain anchor")
                        .font(.caption.weight(.medium))
                        .padding(6)
                        .background(.regularMaterial, in: Capsule())
                }
                .annotationOcclusion(.terrain)
                DioramaMarker("North", coordinate: Turf.destination(from: preset.region.center, meters: 600, bearing: 0), tint: .cyan)
                DioramaMarker("East", coordinate: Turf.destination(from: preset.region.center, meters: 600, bearing: 90), tint: .orange)
                DioramaMarker("South", coordinate: Turf.destination(from: preset.region.center, meters: 600, bearing: 180), tint: .pink)
                DioramaMarker("West", coordinate: Turf.destination(from: preset.region.center, meters: 600, bearing: 270), tint: .green)
            }
            // The Canyon preset carries a marker so selection has something to select.
            if preset.id == "canyon" {
                DioramaMarker(
                    "Yavapai Point",
                    coordinate: CLLocationCoordinate2D(latitude: 36.0667, longitude: -112.1170),
                    id: "yavapai-point"
                )
                .tint(.orange)
                .tag(Place.yavapaiPoint)
                DioramaPolygon(Polygon([
                    Coordinate(latitude: 36.045, longitude: -112.16),
                    Coordinate(latitude: 36.065, longitude: -112.16),
                    Coordinate(latitude: 36.065, longitude: -112.13),
                    Coordinate(latitude: 36.045, longitude: -112.13)
                ]), id: "survey-area")
                .fill(selectedAnnotation == .surveyArea ? .orange.opacity(0.45) : .orange.opacity(0.15))
                .stroke(.orange, style: DioramaStrokeStyle(width: .geographicMeters(25), lineJoin: .round))
                .tag(Place.surveyArea)
                DioramaCircle(center: Coordinate(latitude: 36.0667, longitude: -112.1170), radius: 500, id: "observation-radius")
                    .fill(.blue.opacity(selectedAnnotation == .observationRadius ? 0.45 : 0.15))
                    .stroke(.blue, style: DioramaStrokeStyle(width: .geographicMeters(20), dash: [80, 40]))
                    .tag(Place.observationRadius)
            }
        }
        .dioramaStyle(style)
        .dioramaEffect(preset.effect)
        .dioramaARPlacement($arActive)
        .dioramaControls {
            VStack {
                HStack {
                    DioramaCompass()
                    DioramaResetButton()
                    DioramaPerspectiveToggle()
                    DioramaFitButton()
                }
                Text("Ground").font(.caption)
                DioramaZoomControls(target: .ground)
                Text("Camera").font(.caption)
                DioramaZoomControls(target: .camera)
                DioramaPitchControl().frame(width: 140)
                DioramaKeyboardHelp()
                CameraExampleControls(camera: position.camera ?? preset.camera)
                if preset.id == "camera" {
                    Button("Select viewpoint", systemImage: "mappin.and.ellipse") {
                        selectedAnnotation = selectedAnnotation == .cameraLabel ? nil : .cameraLabel
                    }
                    .accessibilityIdentifier("select-viewpoint-alternative")
                    Button("Move viewpoint", systemImage: "arrow.up.and.down") { annotationMoved.toggle() }
                        .accessibilityIdentifier("move-viewpoint")
                }
            }
            .buttonStyle(.bordered)
            .labelStyle(.iconOnly)
        }
        // Zooming out (fingers pinching together) widens the ground the chunk covers, and once it
        // is covering about as much world as a flat cut can, the chunk dissolves into the globe;
        // spin that and zoom back in (fingers apart) to cut a chunk somewhere else.
        .globeTransition()
        // The region and the style are live: switching presets relocates or rebuilds the diorama
        // in place, with no `.id` identity tricks.
        .onChange(of: preset.id) { _, _ in
            groundPosition = DioramaGroundPosition(region: preset.region)
            position = .camera(preset.camera)
        }
        .task {
            position = .camera(preset.camera)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// All six content types use the same streamed surface; gaps remain empty until tiles arrive.
    @DioramaContentBuilder private var photorealPlacementContent: some DioramaContent {
        let center = preset.region.center
        DioramaMarker("Visible mesh", coordinate: preset.region.center, id: "mesh-pin")
            .tint(.orange)
        DioramaMarker("Mesh +100 m", coordinate: center.at(altitude: 100), tint: .pink,
                      altitude: .relativeToGround, id: "mesh-offset-pin")
        DioramaAnnotation("Surface anchor", coordinate: Turf.destination(from: center, meters: 100, bearing: 0), id: "mesh-label") {
            Text("Visible mesh anchor")
                .font(.caption.weight(.semibold))
                .padding(8)
                .background(.regularMaterial, in: Capsule())
        }
        .annotationOcclusion(.alwaysVisible)
        DioramaPolyline(coordinates: [
            Turf.destination(from: center, meters: 450, bearing: 240),
            center,
            Turf.destination(from: center, meters: 450, bearing: 60)
        ], id: "mesh-line")
        .stroke(.yellow, style: DioramaStrokeStyle(width: .geographicMeters(12), lineCap: .round))
        DioramaPolygon(Polygon([
            Turf.destination(from: center, meters: 150, bearing: 120),
            Turf.destination(from: center, meters: 150, bearing: 180),
            Turf.destination(from: center, meters: 150, bearing: 240)
        ]), id: "mesh-area")
        .fill(.green.opacity(0.3))
        .stroke(.green, width: .geographicMeters(8))
        DioramaCircle(center: Turf.destination(from: center, meters: 250, bearing: 90), radius: 100, id: "mesh-circle")
            .fill(.cyan.opacity(0.3))
            .stroke(.cyan, width: .geographicMeters(8))
        if let image = Self.meshSurveyImage {
            DioramaImageOverlay(image: image, bounds: GeographicBounds(
                west: center.longitude - 0.0025, south: center.latitude + 0.0015,
                east: center.longitude - 0.0015, north: center.latitude + 0.0025
            ), id: "mesh-image").opacity(0.6)
        }
    }

    /// A tiny north-up survey grid makes draped UV orientation visible without another fetch.
    private static let meshSurveyImage: DioramaImageResource? = {
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                      bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.85, green: 0.3, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(2)
        for coordinate in stride(from: 0, through: 64, by: 16) {
            context.move(to: CGPoint(x: coordinate, y: 0)); context.addLine(to: CGPoint(x: coordinate, y: 64))
            context.move(to: CGPoint(x: 0, y: coordinate)); context.addLine(to: CGPoint(x: 64, y: coordinate))
        }
        context.strokePath()
        context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 48, width: 16, height: 16))
        guard let image = context.makeImage() else { return nil }
        return DioramaImageResource(id: "demo-mesh-survey", revision: "1", image: image,
                                    attribution: "Maquette demo survey grid")
    }()

    private var buildingsToggle: some View {
        Toggle("Buildings", isOn: $buildingsVisible)
            .font(.subheadline.weight(.medium))
            .toggleStyle(.switch)
            .tint(.accentColor)
            .padding(.horizontal, 16)
            .accessibilityIdentifier("toggle-buildings")
    }

    #if os(visionOS)
    /// The ornament that carries everything the flat layouts stack around the diorama.
    ///
    /// Deliberately buttons rather than a `Picker` menu: fifteen presets behind a menu hides the
    /// point of the demo, and a row of capsules is both the platform's idiom and something a
    /// scripted run can still reach by accessibility identifier.
    private var controlBar: some View {
        VStack(spacing: 14) {
            VStack(spacing: 2) {
                Text(preset.title)
                    .font(.title3.weight(.semibold))
                Text(preset.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(Array(DemoPresets.all.enumerated()), id: \.element.id) { index, item in
                        Button(item.title) { selection = index }
                            .buttonStyle(.borderless)
                            .buttonBorderShape(.capsule)
                            .background(
                                index == selection ? Color.accentColor.opacity(0.55) : .clear,
                                in: .capsule
                            )
                            .accessibilityIdentifier("preset-\(item.id)")
                    }
                }
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.hidden)
            .frame(width: 620)

            if preset.id == "buildings" || !isVolume {
                HStack(spacing: 20) {
                    if preset.id == "buildings" {
                        Toggle("Buildings", isOn: $buildingsVisible)
                            .toggleStyle(.switch)
                            .fixedSize()
                            .accessibilityIdentifier("toggle-buildings")
                    }
                    if !isVolume {
                        // The same demo in a true volume: the chunk with real depth, standing in
                        // the room.
                        Button {
                            openWindow(id: "volume")
                        } label: {
                            Label("Open in a volume", systemImage: "cube")
                        }
                        .accessibilityIdentifier("open-volume")
                    }
                }
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 26)
        .glassBackgroundEffect()
    }
    #endif

    // The flat layouts stack their chrome around the diorama; visionOS floats it in an ornament
    // instead, so none of this is built there.
    #if !os(visionOS)
    private var header: some View {
        VStack(spacing: 2) {
            Text(preset.title)
                .font(.title2.weight(.semibold))
            Text(preset.caption)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .overlay(alignment: .trailing) {
            #if os(iOS)
            // Places the diorama on a real surface at its true physical size. Needs a device —
            // the simulator has no camera to track planes with.
            Button {
                arActive.toggle()
            } label: {
                Image(systemName: arActive ? "arkit.badge.xmark" : "arkit")
                    .font(.title3)
            }
            .padding(.trailing, 16)
            .accessibilityIdentifier("toggle-ar")
            #endif
        }
    }

    private var presetPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(DemoPresets.all.enumerated()), id: \.element.id) { index, item in
                    chip(item.title, id: item.id, isSelected: index == selection) {
                        selection = index
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 12)
    }

    private func chip(
        _ title: String,
        id: String,
        isSelected: Bool,
        select: @escaping () -> Void
    ) -> some View {
        Button(action: select) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(isSelected ? Color.accentColor : Color(white: 0.18))
                )
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
        }
        .accessibilityIdentifier("preset-\(id)")
    }
    #endif
}


/// The environment proxy targets only the diorama hosting this controls overlay.
private struct CameraExampleControls: View {
    @Environment(\.dioramaCamera) private var cameraProxy
    let camera: DioramaCamera

    var body: some View {
        Button {
            var east = camera
            east.heading = .degrees(90)
            cameraProxy?.setCamera(east, transition: .easeInOut(duration: 0.6))
        } label: {
            Label("Face east", systemImage: "arrow.right")
        }
        .disabled(cameraProxy?.capabilities.canOrbit != true)
        .accessibilityIdentifier("camera-face-east")

        Button {
            cameraProxy?.cancel()
        } label: {
            Label("Cancel camera movement", systemImage: "stop.circle")
        }
        .disabled(cameraProxy?.activeRequest == nil)
        .accessibilityIdentifier("camera-cancel")
    }
}

/// Local state belongs to this label while its place or the camera moves.
private struct StatefulAnnotationCard: View {
    let selected: Bool
    @State private var count = 0
    @State private var note = "Viewpoint"

    var body: some View {
        VStack(spacing: 6) {
            Text(selected ? "Viewpoint selected" : "Camera viewpoint")
                .font(.caption.weight(.semibold))
                .accessibilityIdentifier("annotation-title")
            Button("Visits: \(count)") { count += 1 }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("annotation-counter")
            TextField("Note", text: $note)
                .textFieldStyle(.roundedBorder)
                .frame(width: 115)
                .accessibilityIdentifier("annotation-note")
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.orange : .white.opacity(0.25)))
    }
}

#if !os(visionOS)
/// Scroll ownership and independent focus can be checked without leaving the demo.
private struct InputLabView: View {
    let region: DioramaRegion
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("Click a scene to focus it. Arrows pan; Option arrows orbit. Shift-wheel zooms its camera. Wheel over labels or this page scrolls normally.")
                    .font(.callout).padding()
                InputLabScene(title: "First scene", region: region)
                Text("Page between scenes — wheel here scrolls the page").padding(24)
                InputLabScene(title: "Second scene", region: region)
                Text("End of input lab").padding(60)
            }
        }
        .accessibilityIdentifier("input-lab-scroll")
    }
}

private struct InputLabScene: View {
    let title: String
    let region: DioramaRegion
    @State private var camera = DioramaCameraPosition.camera(DioramaCamera(pitch: .degrees(50), distance: 1.6))
    @State private var ground: DioramaGroundPosition
    @State private var note = "Edit me"
    init(title: String, region: DioramaRegion) {
        self.title = title; self.region = region
        _ground = State(initialValue: DioramaGroundPosition(region: region))
    }
    var body: some View {
        VStack {
            Text("\(title): heading \(Int((camera.camera?.heading.degrees ?? 0).rounded()))°, distance \(camera.camera?.distance ?? 0, specifier: "%.2f"), radius \(Int(ground.region.radius)) m")
                .accessibilityIdentifier(title == "First scene" ? "input-first-status" : "input-second-status")
            DioramaView(groundPosition: $ground, shape: .rectangular(width: 0.8, depth: 0.8), cameraPosition: $camera) {
                DioramaAnnotation("Editable note", coordinate: region.center, id: "note") {
                    TextField("Scene note", text: $note).textFieldStyle(.roundedBorder).frame(width: 120)
                }.annotationOcclusion(.alwaysVisible)
            }
            .dioramaStyle(.standard(exaggeration: 1.6, chunk: .canyon, panRange: 0.8))
            .dioramaControls {
                VStack {
                    DioramaCompass()
                    DioramaZoomControls(target: .ground)
                    DioramaZoomControls(target: .camera)
                    DioramaPerspectiveToggle()
                    DioramaFitButton()
                    DioramaKeyboardHelp()
                }.buttonStyle(.bordered).labelStyle(.iconOnly)
            }
            .frame(height: 340)
        }
        .padding(.horizontal, 16)
    }
}
#endif
