# WorkoutFixtures

WorkoutFixtures is a Swift Concurrency-first toolkit for capturing, sanitizing,
generating, and replaying portable workout fixtures. It deliberately models the
workout data—not `HKHealthStore`—so the same fixture works in unit tests,
SwiftUI previews, command-line tools, Linux CI, and HealthKit integration tests.

## Requirements

- Swift 6.2 / Xcode 26 or newer
- iOS 17+, watchOS 10+, or macOS 14+ for HealthKit integration
- Linux is supported by the portable products

The package uses Swift 6 language mode, complete concurrency checking,
nonisolated default isolation, and caller-isolated async functions. All public
models are immutable `Sendable` values. UI state in the example host app is the
only code isolated to `@MainActor`.

## Products

| Product | Purpose |
| --- | --- |
| `WorkoutFixtures` | Models, strict JSON codec/schema, validation, redaction, generation, and in-memory/JSON sources |
| `WorkoutFixturesHealthKit` | Explicit authorization plus HealthKit capture and replay adapters |
| `WorkoutFixturesTestSupport` | Deterministic run, walk, and cycling presets plus bundle loading |
| `workout-fixture` | Inspect, validate, redact, migrate, and generate fixtures |

Swift Argument Parser is linked only by the CLI. The three library products have
no external dependencies.

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

The source uses HealthKit async query descriptors. The sink is an actor that
serializes builder state, checks cancellation between bounded sample/route
chunks, discards unfinished builders, and attempts to remove already-persisted
samples if an import fails.

The entitled SwiftUI host app is at
`Examples/WorkoutFixturesHost/WorkoutFixturesHost.xcodeproj`. It can:

- authorize and list HealthKit workouts;
- capture and validate portable fixtures;
- import fixture files through the system document picker;
- export shareable, redacted fixtures;
- export full fixtures only after a privacy confirmation;
- replay fixtures into simulator HealthKit;
- delete the last workout it imported.

### Physical device to a mock source

On the physical device:

1. Open `WorkoutFixturesHost.xcodeproj`, select the host scheme and your device,
   and choose your own development team locally. The repository intentionally
   contains no team identifier; do not commit Xcode's signing change.
2. Run the host and tap **Export All Workouts for Mocking**. This action requests
   read authorization itself; **Authorize and Refresh** is only needed to browse
   or export one selected workout.
3. Confirm the privacy warning and save `workout-fixtures-archive.json` to iCloud
   Drive or AirDrop it to your Mac. It contains every supported running, walking,
   and cycling workout, including associated metric samples, events, and routes.

Add that one file as a resource of a test-support target or a Debug-only app
target, then load it directly without HealthKit authorization or a Simulator
host:

```swift
import WorkoutFixtures

let source: any WorkoutFixtureSource = try JSONWorkoutSource(
    bundle: .main,
    resource: "workout-fixtures-archive"
)

let workouts = try await source.summaries(matching: WorkoutQuery())
let workout = try await source.fixture(for: workouts[0].id)
```

Use `bundle: .module` when the archive is a SwiftPM target resource. The same
`JSONWorkoutSource` also accepts the original single-workout fixture files, so
call sites do not need separate archive and fixture code paths. Do not include a
private device archive in a production application bundle.

### Optional replay into Simulator HealthKit

Most tests and previews should inject `WorkoutFixtureSource` and stop there. If
the code under test must exercise the real `HKHealthStore` adapter, the host can
still replay an individual fixture:

1. Build and run the same host app on a booted iOS Simulator.
2. Export one full fixture on the device. If it is in iCloud Drive, tap **Import
   Fixture File** and select it.
   To transfer a file from the Mac without iCloud, first install the host and
   then copy it into the app's Simulator Documents directory:

   ```console
   APP_DATA="$(xcrun simctl get_app_container booted dev.workoutfixtures.host data)"
   cp "/path/to/workout.json" "$APP_DATA/Documents/"
   ```

   If more than one Simulator is booted, replace `booted` with the destination
   Simulator's UDID from `xcrun simctl list devices booted`.

   In the picker, choose **On My iPhone → Workout Fixtures**.
3. Confirm that validation reports zero errors, tap **Authorize and Refresh**,
   and then tap **Write Fixture to HealthKit**.
4. Inspect the workout in the Simulator's Health app. Use **Remove Last
   Imported Workout** when you are finished.

Treat every full fixture or archive as private development data. **Export
Shareable Copy** changes dates and identifiers and removes the GPS route and
captured source metadata from a selected fixture.

The SPM package cannot install a replacement system `HKHealthStore`. Direct
archive loading requires the application to inject `WorkoutFixtureSource` (or
adapt it to the application's own health-data protocol). That boundary is what
makes the same mock work in unit tests, previews, Simulator builds, macOS tools,
and Linux CI.

## Privacy

Workout dates, routes, device details, and source application metadata can
identify a person. The sharing preset regenerates the fixture ID, shifts dates
by a deterministic whole-day offset, removes the route, and removes captured
source metadata:

```swift
let shareable = try WorkoutRedactor().redact(captured, seed: 42)
```

Treat raw fixtures as sensitive health data. Generated or simulator-imported
samples are attributed to the importing application, not the original device.

## CLI

```console
swift run workout-fixture inspect fixture.json
swift run workout-fixture validate fixture.json --diagnostics-format json
swift run workout-fixture redact fixture.json --output safe.json --seed 42
swift run workout-fixture generate fixture.json \
  --recipe Examples/focused-recipe.json \
  --count 10 --seed 42 --output-directory Generated
swift run workout-fixture migrate fixture.json --output canonical.json
```

Diagnostics go to stderr; requested payloads go to stdout. Files are written
atomically. Exit status `64` represents invalid CLI usage and `1` represents
validation or operational failure.

## Schema and validation

Schema v1 uses ISO-8601 UTC timestamps and the canonical units `count/min`, `m`,
and `kcal`. The bundled JSON Schema is Draft 2020-12. Decoding rejects future
versions and unknown fields by default; `.ignore` is an explicit recovery mode.

Samples are canonical. Summaries such as total distance, active energy, and
average heart rate are derived so stored totals cannot disagree with timelines.
Validation returns stable issue codes and JSON paths. Errors block generation
and HealthKit writes; warnings preserve unusual but representable data.

## Testing

```console
swift test
```

Package suites use Swift Testing and run safely in parallel. The host project
contains a Swift Testing suite and XCUITest coverage. Its real HealthKit
round-trip suite is serialized, tagged `healthKitIntegration`, and disabled
unless `WORKOUT_FIXTURES_HEALTHKIT_INTEGRATION=1` is set on an entitled,
pre-authorized simulator runner.

## License

WorkoutFixtures is available under the MIT License.
