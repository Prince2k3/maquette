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
