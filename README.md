# WorkoutFixtures

WorkoutFixtures is a Swift Concurrency-first toolkit for capturing, sanitizing,
generating, and replaying portable workout fixtures. It deliberately models the
workout data—not `HKHealthStore`—so the same fixture works in unit tests,
SwiftUI previews, command-line tools, Linux CI, and HealthKit integration
tests.

Full documentation lives in the DocC catalog (`xcodebuild docbuild` or Xcode's
**Product → Build Documentation**), starting with the *Installation and Usage*
article. Agent-facing conventions live in [AGENTS.md](AGENTS.md).

## Requirements

- Swift 6.2 / Xcode 26 or newer
- iOS 17+, watchOS 10+, or macOS 14+ for HealthKit integration
- Linux is supported by the portable products

The package uses Swift 6 language mode, complete concurrency checking,
nonisolated default isolation, and caller-isolated async functions. All public
models are immutable `Sendable` values. UI state is isolated to `@MainActor`
only in `WorkoutFixturesDebugUI` and the example host app.

## Products

| Product | Purpose |
| --- | --- |
| `WorkoutFixtures` | Models, strict JSON codecs/schemas, validation, redaction, generation, GPX import, in-memory/JSON sources, launch configuration |
| `WorkoutFixturesHealthKit` | Explicit authorization, HealthKit capture and replay adapters, `WorkoutStoreFactory` |
| `WorkoutFixturesTestSupport` | Deterministic presets, bundle loading, and test doubles (`InMemoryWorkoutStore`, `RecordingWorkoutSink`, `FailingWorkoutSource`) |
| `WorkoutFixturesDebugUI` | Embeddable SwiftUI debug panel: capture, export, import, and replay fixtures from any HealthKit-entitled app |
| `workout-fixture` | Inspect, validate, split, redact, migrate, generate, and import GPX fixtures |

Swift Argument Parser is linked only by the CLI. The library products have no
external dependencies.

## Package usage

```swift
dependencies: [
    .package(url: "https://github.com/<organization>/WorkoutFixtures.git", from: "1.0.0")
]
```

Use a portable source in tests or previews:

```swift
import WorkoutFixtures
import WorkoutFixturesTestSupport

let fixture = try WorkoutFixturePreset.outdoorRun.fixture()
let source: any WorkoutFixtureSource = InMemoryWorkoutSource(fixtures: [fixture])
let summaries = try await source.summaries(matching: WorkoutQuery())
```

Generate deterministic variations. Every output and transform receives a
derived seed, so results do not depend on task scheduling order:

```swift
let recipe = GenerationRecipe(transforms: [
    .shiftDate(days: IntegerRange(7 ... 21)),
    .scaleDuration(DoubleRange(0.9 ... 1.1)),
    .scaleMetric(.distance, factor: DoubleRange(0.95 ... 1.05)),
    .addNoise(to: .heartRate, standardDeviation: 3, bounds: 35 ... 210),
    .translateRoute(to: Coordinate(latitude: 52.2297, longitude: 21.0122)),
])

let generated = try await TemplateWorkoutGenerator().generate(
    count: 10,
    from: fixture,
    recipe: recipe,
    seed: 42
)
```

Create a fixture from a GPX track (route, derived distance series, and heart
rate from `gpxtpx` extensions):

```swift
let fixture = try GPXWorkoutImporter().fixture(contentsOf: gpxURL)
```

## Injecting mocked workouts into a running app

Apps depend on the protocols (`WorkoutFixtureSource`, `WorkoutFixtureSink`,
`WorkoutFixtureDeleting`) and build their stores once through the factory:

```swift
import WorkoutFixturesHealthKit

let (source, sink) = try WorkoutStoreFactory.make(
    presetFixtures: WorkoutFixturePreset.allFixtures
)
```

By default the factory returns the real HealthKit adapters. When the process
is launched with a fixture mode, it returns fixture-backed stores instead — so
UI tests and Debug builds inject mock workouts with zero app-code changes:

```swift
let app = XCUIApplication()
app.launchEnvironment["WORKOUT_FIXTURES_MODE"] = "presets"
app.launch()
```

Supported modes: `live`, `presets`, `json` (+ `WORKOUT_FIXTURES_PATH`), and
`resource` (+ `WORKOUT_FIXTURES_RESOURCE`).

## HealthKit

HealthKit authorization is always explicit; reading or writing never presents
authorization UI implicitly:

```swift
import HealthKit
import WorkoutFixturesHealthKit

let healthStore = HKHealthStore()
try await HealthKitAuthorizationController(healthStore: healthStore)
    .requestAuthorization(for: .readWrite)

let source = HealthKitWorkoutSource(healthStore: healthStore)
let sink = HealthKitWorkoutSink(healthStore: healthStore)

let fixture = try await source.fixture(for: workoutID)
let stored = try await sink.store(fixture)
```

The source pushes the query's date window, activities, sort, and limit into
HealthKit and reads each workout's own time zone from its metadata. The sink is
an actor that writes bounded sample/route chunks with cooperative cancellation,
stamps time-zone and indoor metadata for faithful round trips, and rolls back
already-persisted samples (children before the parent workout) if an import
fails — preserving the original error.

## Embedding the exporter in your own app

Any app that already holds the HealthKit entitlement can embed the debug panel
and skip the standalone host app entirely:

```swift
import WorkoutFixturesDebugUI

#if DEBUG
    WorkoutFixtureDebugView(model: WorkoutFixtureDebugModel())
#endif
```

Requirements for the hosting app: the HealthKit capability plus
`NSHealthShareUsageDescription`/`NSHealthUpdateUsageDescription`. The panel
lists and captures workouts, exports shareable (redacted) or full fixtures and
one-file archives, imports fixture files, replays fixtures into HealthKit, and
deletes the workouts it imported.

The entitled reference integration is
`Examples/WorkoutFixturesHost/WorkoutFixturesHost.xcodeproj` — a thin shell
around the same panel, kept as the runnable target for UI and integration
tests.

### Physical device to a mock source

1. On the device, run an app embedding the debug panel (or the host app —
   select your own development team locally; the repository intentionally
   contains no team identifier, and CI enforces that).
2. Tap **Export All Workouts for Mocking**, confirm the privacy warning, and
   save `workout-fixtures-archive.json` to iCloud Drive or AirDrop it to your
   Mac.
3. Optionally fan the archive out into per-test fixtures:

   ```console
   workout-fixture split workout-fixtures-archive.json --output-directory Fixtures
   ```

4. Add the archive (or split fixtures) to a test-support target and load it
   without HealthKit or a simulator host:

   ```swift
   let source: any WorkoutFixtureSource = try JSONWorkoutSource(
       bundle: .main,
       resource: "workout-fixtures-archive"
   )
   ```

Use `bundle: .module` when the archive is a SwiftPM target resource.
`JSONWorkoutSource` accepts both archives and single-fixture files. Do not
include a private device archive in a production application bundle.

### Optional replay into Simulator HealthKit

Most tests and previews should inject `WorkoutFixtureSource` and stop there. If
the code under test must exercise the real `HKHealthStore` adapter, run the
host (or your embedding app) on a booted simulator, import a fixture file via
**Import Fixture File** (or copy it into the app's Documents directory with
`xcrun simctl get_app_container booted dev.workoutfixtures.host data`), then
tap **Authorize and Refresh** and **Write Fixture to HealthKit**. Use **Remove
Last Imported Workout** when finished.

The SPM package cannot install a replacement system `HKHealthStore`. Injecting
`WorkoutFixtureSource` at the app boundary is what makes the same mock work in
unit tests, previews, simulator builds, macOS tools, and Linux CI.

## Privacy

Workout dates, routes, device details, and source application metadata can
identify a person. The sharing preset regenerates the fixture ID, shifts dates
by a deterministic whole-day offset, removes the route, and removes captured
source metadata:

```swift
let shareable = try WorkoutRedactor().redact(captured, seed: 42)
```

Redacted output never contains the seed, and the regenerated identifier is a
one-way mix of the seed and the discarded original identifier, so holders of a
shareable fixture cannot reverse the date shift. Treat raw fixtures as
sensitive health data. Generated or simulator-imported samples are attributed
to the importing application, not the original device.

## CLI

```console
swift run workout-fixture inspect fixture-or-archive.json [--json]
swift run workout-fixture validate fixture-or-archive.json --diagnostics-format json
swift run workout-fixture split archive.json --output-directory Fixtures [--redact --seed 42]
swift run workout-fixture redact fixture.json --output safe.json --seed 42 \
  [--preserve-route] [--preserve-source]
swift run workout-fixture generate fixture.json \
  --recipe Examples/focused-recipe.json \
  --count 10 --seed 42 --output-directory Generated
swift run workout-fixture migrate fixture.json --output canonical.json
swift run workout-fixture import-gpx track.gpx --output imported.json \
  [--activity running] [--location outdoor] [--time-zone UTC] [--no-distance-series]
swift run workout-fixture schema fixture|archive|recipe
```

Payloads and confirmations go to stdout; diagnostics go to stderr
(`--diagnostics-format json` emits NDJSON — one
`{"severity","code","path","message"}` object per line). Files are written
atomically; filenames derived from fixture IDs are sanitized. Exit status `64`
is invalid usage and `1` is a validation or operational failure — both are
asserted by tests.

## Schema and validation

Schema v1 uses ISO-8601 UTC timestamps and the canonical units `count/min`,
`m`, and `kcal`. Draft 2020-12 JSON Schemas for fixtures, archives, and
generation recipes ship in the module (`workout-fixture schema …` prints
them). Decoding rejects future versions and unknown fields by default;
`.ignore` is an explicit recovery mode. Recipes are decoded strictly too — a
typo'd key is an error, never silently dropped.

Samples are canonical. Summaries such as total distance, active energy, and
average heart rate are derived so stored totals cannot disagree with
timelines. Validation returns stable issue codes and JSON paths. Errors block
generation and HealthKit writes; warnings preserve unusual but representable
data.

## Testing

```console
make test        # portable package tests
make test-host   # host app unit + UI tests on a simulator
make lint        # swift-format lint (matches CI)
make smoke       # CLI generate → validate → inspect round trip
```

Package suites use Swift Testing and run safely in parallel.
`WorkoutFixturesTestSupport` ships the doubles the host tests use — no
`HKHealthStore` is constructed in unit tests. The real HealthKit round-trip
suite is serialized, tagged `healthKitIntegration`, and disabled unless
`WORKOUT_FIXTURES_HEALTHKIT_INTEGRATION=1` reaches the simulator test process
(CI passes it as `TEST_RUNNER_WORKOUT_FIXTURES_HEALTHKIT_INTEGRATION`); the
runner's simulator must be pre-authorized by hand once — there is no supported
automation for the HealthKit permission modal.

## License

WorkoutFixtures is available under the MIT License.
