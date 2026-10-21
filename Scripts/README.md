---
title: Release validation scripts
tags: [maquette, validation, ci]
created: 2026-10-20
updated: 2026-10-21
status: active
type: reference
---

# Release validation scripts

This folder holds local and CI release checks for [[map-content-camera-api-plan]] and
[[release-notes-map-content-camera]]. It is tooling, outside the shipped library target.

`python3 Scripts/validate-documentation.py` checks that the complete marked migration declarations
exactly match the plain-import Swift Testing fixture. Normal package tests compile and construct
those declarations without loading terrain. The checker fails if either published example drifts.

For DocC, first run `swift package dump-symbol-graph --minimum-access-level public`, then pass its
reported symbol-graph directory to
`python3 Scripts/validate-documentation.py --compile-docc --symbol-graphs PATH`.
DocC warnings fail this gate. This checks catalog structure, references, and public symbols;
Swift compilation of the examples remains a separate required gate.

`bash Scripts/validate-platform.sh ios` and `bash Scripts/validate-platform.sh visionos` discover
installed SDKs with `xcrun` and compile the library plus tests at iOS 18 and visionOS 2. The host
`swift test` and `swift test -c release` jobs use the package’s macOS 15 floor. Both configurations
are required: optimized async closure lowering can expose failures absent from Debug. These are compile checks, not hardware tests.
`Fixtures/Rejected` contains intentional removed-API examples, outside all source/test targets.
Run `verify-production-rejections.py --modules PATH` against the built public module; it requires
each old spelling to fail with its intended diagnostic. The workflow in `.github/workflows/ci.yml`
runs these gates, the prototype contract, and both production/prototype compiler rejection checks. No credentials or live tiles are required.


`bash Scripts/validate-demo.sh macos|ios|visionos` generates the existing XcodeGen project and builds
the complete demo, without signing. It preserves an existing local `Secrets.swift`; on clean CI it
copies the empty credentials template temporarily and removes only that placeholder on exit.
XcodeGen must be installed. The CI jobs install it when absent. Builds do not launch provider loads.

Opt-in performance observations run separately from CI’s correctness gates:

```sh
MAQUETTE_RUN_CONTENT_BENCHMARK=1 swift test -c release --filter MapContentBenchmark
MAQUETTE_RUN_PAN_BENCHMARK=1 swift test -c release --filter PanBenchmark
```

Run on a machine with a working RealityKit graphics context and record build, machine, workload,
CPU preparation, memory observations, and exclusions. Neither CPU elapsed time nor resident-set
samples establish frame/GPU cost or long-run memory stability; those remain separate hardware
capture tasks. There are no portable timing thresholds in CI.

The content harness reports mean, p95 and maximum completed pan/ground-zoom rebuild costs,
including asynchronous geometry and resource updates. Main-actor submission and completion
costs are separate. Repeat after competing builds/rendering stop and retain all results; a single
mean cannot establish a 16 ms target. Nominal-input checks also print the observed input cadence.

## Rendered interaction diagnostics

[[map-overlay-frame-profiling]] records the Mac capture and iPad simulator observations from
2026-10-21. `Fixtures/overlay-profile-2026-10-21.json` preserves the numeric results. Those
observations do not establish a cross-platform 60 fps pass.

The opt-in driver in `Platform/DioramaProfileTour.swift` is compiled out unless
`MAQUETTE_PROFILING` is defined. It also requires the runtime environment variable
`MAQUETTE_PROFILE=1`. It waits for initial content, warms up for eight seconds, then drives ten
seconds each of pan, ground zoom and camera zoom through the existing intent methods. It emits
Points of Interest intervals and `ProfileTour` logs with input deadlines, gaps, completed builds
and hidden overlay record samples. These samples are diagnostics, not frame measurements.
Deactivating the scene cancels the tour and reverses outstanding movement; reactivation restarts it.

For example, build a separate Release Mac demo:

```sh
xcodebuild -project Demo/MaquetteDemo.xcodeproj -scheme MaquetteDemo \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /tmp/maquette-profile CODE_SIGNING_ALLOWED=NO \
  PRODUCT_BUNDLE_IDENTIFIER=com.maquette.MaquetteProfile \
  'OTHER_SWIFT_FLAGS=$(inherited) -D MAQUETTE_PROFILING' ONLY_ACTIVE_ARCH=YES build
```

Launch the exact binary with `MAQUETTE_PROFILE=1 MAQUETTE_PRESET=performance` and
`MAQUETTE_WORKLOAD=path|polygons|images` (choose one value). Keep its window active. Attach
Instruments to its PID, using `Game Performance Overview` plus `Points of Interest` for 60 seconds.
Attaching by PID avoids Launch Services resolving an older demo with the same executable name.
Do not build, inspect the UI, or run other captures during the measured phases. Validate phase
completion and target PID/layer before summarizing counters; exclude canceled intervals.

On a simulator, prefix runtime environment variables with `SIMCTL_CHILD_` when using
`xcrun simctl launch`. Empty Instruments tables are unavailable measurements, not zero cost.
Input cadence and simulator results cannot verify physical-device frame rate. Obtain per-frame
timing and real gesture/hardware captures before declaring the smooth 60 fps goal achieved.
