# Capturing Real Workouts

From a physical device to a mock source in four steps.

## Capture on the device

Run an app that embeds `WorkoutFixtureDebugView` (or the example host app) on
your device and tap **Export All Workouts for Mocking**. Save
`workout-fixtures-archive.json` to iCloud Drive or AirDrop it to your Mac. It
contains every supported workout with samples, events, and routes.

> Important: A full archive contains exact dates, GPS routes, and device
> metadata. Treat it as private health data and never bundle it into a
> production app.

## Fan it out (optional)

```console
workout-fixture inspect workout-fixtures-archive.json
workout-fixture validate workout-fixtures-archive.json
workout-fixture split workout-fixtures-archive.json --output-directory Fixtures
```

Add `--redact --seed 42` to `split` to produce shareable fixtures in one step.

## Load it in your app or tests

```swift
let source: any WorkoutFixtureSource = try JSONWorkoutSource(
  bundle: .main,
  resource: "workout-fixtures-archive"
)
```

Use `bundle: .module` for SwiftPM target resources. No HealthKit authorization
or simulator host is needed — this is the recommended path for tests,
previews, and Linux CI.

## Redaction guarantees

``WorkoutRedactor`` with the sharing policy regenerates the identifier, shifts
all dates by a deterministic whole-day offset, removes the route, and removes
captured source metadata. The redacted output does not contain the seed, and
the regenerated identifier is a one-way mix of the seed and the discarded
original identifier — holders of a shareable fixture cannot reverse the date
shift.

## Optional: replay into simulator HealthKit

Most tests should stop at injecting `WorkoutFixtureSource`. When code must
exercise the real `HKHealthStore` adapter, run the debug panel in a simulator,
import a fixture file, and tap **Write Fixture to HealthKit** — then **Remove
Last Imported Workout** when finished.
