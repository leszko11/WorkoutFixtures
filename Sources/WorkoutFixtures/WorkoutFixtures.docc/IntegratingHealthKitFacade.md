# Integrating with an Existing HealthKit Facade

WorkoutFixtures models **workout data**, not `HKHealthStore`. SPM cannot replace
the system HealthKit store. Apps that already wrap HealthKit behind their own
protocol (`WorkoutsClient`, `HealthKitServiceProtocol`, …) should pick one of
the three supported patterns below.

## Pattern A — Inject a fixture-backed facade

Use when unit tests, UI tests, or Debug builds should **not** touch HealthKit.

1. Load fixtures with ``JSONWorkoutSource`` or ``FixtureWorkoutStore/load(contentsOf:validate:)``.
2. ``FixtureWorkoutStore`` validates on enable so a bad archive fails immediately.
3. Map ``WorkoutSummary`` / ``WorkoutFixture`` into your domain types.
4. Inject your existing mock client (`MockWorkoutsClient`, `FixtureHealthService`, …).

```swift
import WorkoutFixtures

let store = try FixtureWorkoutStore.load(contentsOf: archiveURL)
let summaries = try await store.summaries(matching: WorkoutQuery())
// Map summaries into your WorkoutsClient / HealthService models.
```

Launch-time injection without call-site changes:

```swift
import WorkoutFixturesHealthKit

let (source, sink) = try WorkoutStoreFactory.make(
  presetFixtures: WorkoutFixturePreset.allFixtures
)
```

Set `WORKOUT_FIXTURES_MODE=json` (plus `WORKOUT_FIXTURES_PATH`) or `presets` /
`resource` in the process environment. See ``FixtureLaunchConfiguration``.

Authorization doubles for denial scenarios:

- ``AlwaysAuthorizedHealthAuthorizing``
- ``DenyingHealthAuthorizing``

## Pattern B — Seed real HealthKit

Use when you must exercise the **production** HealthKit pipeline: anchored
queries, observers, background delivery, free-tier limits, and sync code that
talks to `HKHealthStore` directly.

```swift
import WorkoutFixturesHealthKit

let seeder = HealthKitFixtureSeeder()
let stored = try await seeder.seed(contentsOf: archiveURL)  // requests .write
// … run the real sync …
try await seeder.remove(stored)
```

The embeddable ``WorkoutFixtureDebugView`` exposes the same flow as
**Write All to HealthKit** / **Remove All Imported Workouts**.

Capture with ``WorkoutFixtureCaptureOptions/fullDump`` so heart rate, energy,
distance, routes, and elevation metadata are preserved. Lean exports
(``WorkoutFixtureCaptureOptions/lean``) are for small UI-test fixtures only.

## Pattern C — Thin history JSON (no runtime dependency)

Use when the app binary must not link WorkoutFixtures, but you still want a
committed, reproducible workout history (for example plan-evaluation loops).

Offline, on a machine that has the package:

```bash
swift run workout-fixture summarize archive.json.gz \
  --window-days 60 --shift-weeks 0 \
  --merge-policy firstWins \
  --output typical-runner.json
```

The document schema (`WorkoutHistoryDocument`) includes `schemaVersion`, ascent,
average heart rate, and the other summary fields. Decode it with your own
`Codable` types in the app.

Non-workout HealthKit data (body metrics, sleep, VO₂max, HRV) is **out of
scope** for WorkoutFixtures — author those in the app or a sibling package.

## DebugUI and Release builds

Link ``WorkoutFixturesDebugUI`` only from Debug configurations (or gate the
screen with `#if DEBUG`). Do not ship captured archives or the debug panel in
App Store binaries.

## What this package will not do

- Mock `HKHealthStore`, background delivery, or anchored queries in-process
- Replace your domain activity enums or peak/trail heuristics
- Model body / sleep / vitals as workout fixtures
