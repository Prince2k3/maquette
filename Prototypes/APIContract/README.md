---
title: Maquette API contract prototype
tags: [maquette, api, prototype]
created: 2026-10-20
updated: 2026-10-20
status: active
type: reference
---

# Maquette API contract prototype

Executable phase 1 of [[map-content-camera-api-plan]], tracked in [[map-api-phase-1-implementation]]. This separate Swift package depends on the production package by relative path. It adds no product or dependency to the shipped Maquette package.

`MaquetteNext` is a non-rendering prototype. Its view displays a diagnostic message; the camera proxy returns `unavailable` without an internal action receiver. Compiling a polygon, annotation, or fit request does not mean those features render yet. Do not use this package in an application.

## Contract decisions

- `DioramaAnnotation` means a custom SwiftUI label; `DioramaFeature` wraps GeoJSON. Raw features and collections are accepted by the builder. Existing geometry types are reused through public aliases.
- `DioramaContent` exposes only a builder-backed `body`. Internal primitive resolution produces Sendable geometry descriptors. Main-actor view factories, image objects, registry records, and renderer arrays stay outside the public content contract.
- Native SwiftUI `ForEach` uses a specialized `DioramaForEachContent` result. Resolve main-actor closures before storing SwiftUI's nonisolated element closure. IDs must be unique, Hashable, and Sendable. Native `for` loops use positional identity; use `ForEach` when collection elements can reorder.
- Fill is restricted to area primitives and stroke to line/area primitives, including through modifier wrappers. Mixed GeoJSON has `DioramaFeatureStyle` with independent point tint, stroke, and fill. Local modifiers override inherited group defaults; repeated modifiers on the same wrapper replace their earlier value.
- Width is explicitly physical or geographic meters. Dash units follow width units. Circle radius is geographic meters. Image resources carry decoded `CGImage` pixels and explicit caller-owned ID/revision; SwiftUI `Image` alone cannot supply texture pixels to a future renderer.
- Custom label factories are lazy and main-actor isolated. Registry records preserve lifetime IDs on data changes and reorder, and replace closures with current data. Tests establish identity bookkeeping, not rendered SwiftUI `@State` retention or occlusion.
- `initialRegion`/`groundPosition` and `initialCamera`/`cameraPosition` have separate overloads. Conflicting ownership cannot compile. Selection remains generic at the initializer and is erased internally without changing the nongeneric view type.
- Camera heading is the viewing bearing clockwise from north; pitch is measured from overhead. Legacy conversion negates azimuth and uses `90 - elevation`. Distance is scene meters. Focus can be chunk center or a coordinate/altitude reference. Limits use a `pitchDegrees` range because SwiftUI `Angle` does not supply the required ordering contract.
- A camera action returns an acceptance receipt, not an animation completion. Identical repeated commands receive distinct tokens. Supersession cancels the old token, and old completion cannot clear a newer token. Host capabilities govern acceptance independently for every host.
- Interaction permissions are heading, pitch, ground pan, ground zoom, and camera zoom. Camera capability depends on presentation. Point queries and area draping are separate surface capabilities; having a raycast does not establish area draping.

## Run on macOS

From the repository root:

```sh
swift test --package-path Prototypes/APIContract -Xswiftc -warnings-as-errors
```

The public-contract fixtures use plain `import MaquetteNext`. Internal tests exercise resolution, registry reconciliation, ownership, and action semantics. Rejection fixtures are intentionally outside test/source targets; compile them separately after the normal build:

```sh
python3 Prototypes/APIContract/verify-rejections.py \
  --modules Prototypes/APIContract/.build/out/Products/Debug
```

The module directory above is the SwiftBuild output for this checkout. With a different SwiftPM build system, pass the directory containing the built `MaquetteNext.swiftmodule` and `Maquette.swiftmodule`. The checker rejects storage access, marker fills, conflicting ground/camera ownership, and nonisolated annotation construction for their intended diagnostics; an unrelated compiler failure does not pass it.

For sandboxed development, set `CLANG_MODULE_CACHE_PATH` to a writable temporary directory and add `--disable-sandbox` to SwiftPM commands if nested compiler sandboxing is unavailable. The production RealityKit tests may need system-service access.

## Minimum-target compiler probes

`Platform/AnnotationPlatformProbe.swift` calls `RealityViewCameraContent.project(point:to:)` directly on iOS/macOS and instantiates `RealityView` attachments on visionOS. It is included in every library build, with no newer-OS availability escape hatch.

```sh
swift build --package-path Prototypes/APIContract \
  --scratch-path /tmp/maquette-next-ios \
  --triple arm64-apple-ios18.0-simulator \
  --sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk \
  --build-tests -Xswiftc -warnings-as-errors

swift build --package-path Prototypes/APIContract \
  --scratch-path /tmp/maquette-next-vision \
  --triple arm64-apple-xros2.0-simulator \
  --sdk /Applications/Xcode.app/Contents/Developer/Platforms/XRSimulator.platform/Developer/SDKs/XRSimulator.sdk \
  --build-tests -Xswiftc -warnings-as-errors
```

These commands compile the production dependency, prototype, and public/behavioral fixtures. They do not launch a simulator or demonstrate rendered alignment, input, AR, or attachment behavior.

## Handoff to later phases

Phase 2's exact line splitting, holes-aware area tessellation, draping, and geographic helpers now live in the production package as internal raw-geometry modules; see [[map-api-phase-2-implementation]]. Phase 3 connects them to content rendering and interaction. Keep the production API separate until the prototype contract is migrated coherently. Camera application/animation, completion events, tracking/follow ownership, controls, photorealistic surface queries, texture upload, annotation placement/occlusion, and actual SwiftUI state retention remain later-phase work. Geometry resource guards are implemented; runtime frame-time and caching budgets still need the renderer integration.
