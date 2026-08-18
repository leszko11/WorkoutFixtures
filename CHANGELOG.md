# Changelog

All notable changes to this project are documented in this file. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project
has not yet tagged a release.

## [Unreleased]

### Fixed

- `HealthKitWorkoutSink.store(_:)` no longer crashes with an uncatchable
  `NSException` when a write fails after finishing has started: the rollback
  path skips `discard()`/`discardWorkout()` once the corresponding finish call
  was attempted (HealthKit raises if a builder is discarded after finishing).
- Route writes use a standalone `HKWorkoutRouteBuilder` finished explicitly
  with the saved workout. The previous `seriesBuilder(for:)` builder is
  finished by the workout builder itself, so the sink's explicit finish raised
  "This route builder is attached to a workout builder" and every fixture with
  a route failed to store. `HealthKitImportError.routeBuilderUnavailable` was
  removed with the guard that produced it.

### Added

- Gzip transport encoding: `GzipCodec` (zlib-backed, Apple + Linux) compresses
  and decompresses `.json.gz` fixture payloads. `JSONWorkoutSource`, the
  `workout-fixture` CLI, and the debug panel's import flow now accept gzipped
  fixture and archive files transparently; bundle resource lookup also falls
  back to a `.json.gz` resource. Compression is a transport concern only —
  the JSON wire format and schema version are unchanged.

- `WorkoutActivity` now covers every non-deprecated `HKWorkoutActivityType`
  (81 activities, previously running/walking/cycling only). The fixture JSON
  schema's activity enum is generated from the Swift cases and a test asserts
  parity; the HealthKit bridge is bijective and distance samples map to the
  activity-appropriate quantity type (cycling, swimming, wheelchair, downhill
  snow sports, or walking/running). The debug panel picks activities on a
  searchable multi-select screen.
- `WorkoutFixturesDebugUI` product: embeddable `WorkoutFixtureDebugView` /
  `WorkoutFixtureDebugModel` capture-export-import-replay panel for any
  HealthKit-entitled app. The example host app is now a thin shell around it.
  The view embeds with a plain `WorkoutFixtureDebugView()`; workouts are
  browsed on a dedicated screen instead of the main list; `WorkoutExportFilter`
  scopes listing and export by activity, date window, minimum distance and
  duration, an optional workout cap, and optional GPS-route stripping; archive
  export skips (and reports) workouts that fail to capture or validate instead
  of aborting, failing only when nothing could be captured.
- GPX import: `GPXWorkoutImporter` in the portable core and the `import-gpx`
  CLI subcommand (route, haversine-derived distance series, heart rate from
  `gpxtpx` extensions).
- Launch-time fixture injection: `FixtureLaunchConfiguration`
  (`WORKOUT_FIXTURES_MODE=live|presets|json|resource`) and
  `WorkoutStoreFactory.make(...)`, so UI tests inject mock workouts via
  `launchEnvironment` with no app-code changes.
- Protocol seams: `WorkoutFixtureDeleting`, the `WorkoutFixtureStore`
  typealias, and `HealthAuthorizing`; `HealthKitWorkoutSink` conforms to
  deleting, `HealthKitAuthorizationController` to authorizing.
- Test doubles in `WorkoutFixturesTestSupport`: `InMemoryWorkoutStore`,
  `RecordingWorkoutSink`, `FailingWorkoutSource`, and
  `WorkoutFixturePreset.launchStore()`.
- CLI: archive support in `inspect`/`validate`, new `split` subcommand
  (archive → per-fixture files, optional `--redact`), new `schema` subcommand
  printing the bundled JSON Schemas, NDJSON diagnostics, filename
  sanitization, and a strict `GenerationRecipeCodec` with a shipped
  `GenerationRecipe.schema.json`.
- `WorkoutQuery.apply(to:)` public query engine shared by all in-memory
  sources; `fixtures` accessors on `InMemoryWorkoutSource`/`JSONWorkoutSource`;
  defaulted `unknownFields:` policy parameter on the JSON sources.
- Docs: DocC catalog (Installation and Usage, The Fixture Format, Capturing
  Real Workouts), `///` documentation across the public API, `AGENTS.md`.
- Tooling: `Makefile` (test/test-host/lint/format/smoke), `.swift-format`,
  CI lint + CLI-smoke jobs, SwiftPM caching, runtime simulator selection.

### Changed

- **Breaking:** `GenerationTransform` is an enum with associated values
  instead of a struct with optional fields. The JSON wire format is unchanged
  (existing recipe files keep working); invalid transforms now fail at decode
  time instead of apply time. `GenerationTransformKind` is no longer public.
- **Breaking:** redacted fixtures no longer carry `provenance.seed`, and the
  regenerated identifier is a one-way mix of the seed and the discarded
  original identifier (`redacted-<hex>` values change).
- **Breaking:** `HealthKitImportError.cleanupFailed` was removed; when
  rollback also fails, `HealthKitWorkoutSink.store` throws
  `HealthKitStoreFailure` carrying both the original and the cleanup error.
- **Breaking:** the host app's `HostViewModel`/`ContentView`/`FixtureDocument`
  moved into the package as `WorkoutFixtureDebugModel`/
  `WorkoutFixtureDebugView`/`FixtureDocument` (public, injectable, off-main
  encode/decode, cancellable single-flight operations).
- `HealthKitWorkoutSource` pushes date/activity/sort/limit into the HealthKit
  query, assembles summaries concurrently, and reads each workout's time zone
  from `HKMetadataKeyTimeZone`; the sink writes time-zone and indoor metadata
  for faithful round trips.
- `Migrate` (CLI) now validates before writing; `Generate` rejects
  `--count < 1` as a usage error (exit 64).

### Fixed

- `WorkoutValidator` no longer crashes on fixtures whose start date is not
  before their end date; it reports `workout.invalidBounds` instead.
- Redaction is no longer reversible from its own output (the seed used to
  derive the date shift was previously embedded in the redacted fixture).
- `HealthKitWorkoutSink`: removed a cancellation handler that raced in-flight
  builder calls; rollback deletes child samples before the parent workout and
  preserves the original error; removed dead state.
- CI: removed a committed `DEVELOPMENT_TEAM` that failed the pipeline's own
  signing guard; the HealthKit integration workflow now actually forwards its
  gate to the simulator test process (`TEST_RUNNER_` prefix) and fails when
  zero tests ran instead of reporting a vacuous green.
