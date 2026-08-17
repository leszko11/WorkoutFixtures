# Installation and Usage

Add the package, pick the products you need, and inject a workout source.

## Installation

Add WorkoutFixtures to your `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/leszko11/WorkoutFixtures.git", from: "1.0.0")
]
```

Or in Xcode: **File → Add Package Dependencies…** and paste the repository URL.

Pick products per target:

| Product | Add to | Purpose |
| --- | --- | --- |
| `WorkoutFixtures` | App + test targets | Models, codecs, validation, generation, GPX import, portable sources |
| `WorkoutFixturesHealthKit` | App target | Real `HKHealthStore` adapters and launch-time store factory |
| `WorkoutFixturesTestSupport` | Test targets (or Debug-only targets) | Bundled presets and test doubles |
| `WorkoutFixturesDebugUI` | App target, behind `#if DEBUG` | Drop-in capture/export/replay panel |
| `workout-fixture` | Command line | Inspect, validate, split, redact, generate, migrate, import GPX |

Requirements: Swift 6.2 / Xcode 26 or newer; iOS 17+, watchOS 10+, or
macOS 14+ for the HealthKit products. The portable products also build on
Linux.

## Use fixtures in tests and previews

```swift
import WorkoutFixtures
import WorkoutFixturesTestSupport

let fixture = try WorkoutFixturePreset.outdoorRun.fixture()
let source: any WorkoutFixtureSource = InMemoryWorkoutSource(fixtures: [fixture])
let summaries = try await source.summaries(matching: WorkoutQuery())
```

Load a captured archive the same way — `JSONWorkoutSource` accepts single
fixtures and archives with one code path:

```swift
let source = try JSONWorkoutSource(bundle: .main, resource: "workout-fixtures-archive")
```

## Wire your app for launch-time injection

Depend on the protocols and build the stores once through the factory:

```swift
import WorkoutFixturesHealthKit

let (source, sink) = try WorkoutStoreFactory.make(
  presetFixtures: WorkoutFixturePreset.allFixtures
)
```

UI tests then swap HealthKit for fixtures without touching app code:

```swift
let app = XCUIApplication()
app.launchEnvironment["WORKOUT_FIXTURES_MODE"] = "presets"
app.launch()
```

`WORKOUT_FIXTURES_MODE` accepts `live`, `presets`, `json` (with
`WORKOUT_FIXTURES_PATH`), and `resource` (with `WORKOUT_FIXTURES_RESOURCE`).
See ``FixtureLaunchConfiguration``.

## Embed the exporter in your own app

Any app that already holds the HealthKit entitlement can host the debug panel
and skip the standalone host app entirely:

```swift
import WorkoutFixturesDebugUI

#if DEBUG
  WorkoutFixtureDebugView()
#endif
```

The panel lists workouts on a separate screen and exports only what matches
its export filters (activities, date window, minimum distance and duration,
optional route stripping, and a workout cap) — workouts that fail to capture
are skipped and reported rather than aborting the export.

The hosting app needs the HealthKit capability plus
`NSHealthShareUsageDescription`/`NSHealthUpdateUsageDescription`.

## Command-line workflow

```console
swift run workout-fixture inspect archive.json
swift run workout-fixture split archive.json --output-directory Fixtures --redact --seed 42
swift run workout-fixture generate fixture.json --recipe recipe.json \
  --count 10 --seed 42 --output-directory Generated
swift run workout-fixture import-gpx track.gpx --output ride.json --activity cycling
swift run workout-fixture schema fixture
```

Exit codes: `0` success, `1` validation or operational failure, `64` usage
error. Diagnostics go to stderr (`--diagnostics-format json` emits one JSON
object per line); payloads go to stdout.
