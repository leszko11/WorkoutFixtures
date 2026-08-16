# WorkoutFixtures — Agent Guide

Portable workout fixtures for testing HealthKit apps: capture real workouts on a
device, sanitize them, generate variations, and replay them in tests, previews,
and the simulator.

## Product map

| Product | Platforms | Purpose |
| --- | --- | --- |
| `WorkoutFixtures` | Apple + Linux | Models, strict JSON codecs + schemas, validation, redaction, seeded generation, GPX import, in-memory/JSON sources, launch configuration |
| `WorkoutFixturesHealthKit` | Apple only | `HealthKitWorkoutSource`/`Sink`, explicit authorization, `WorkoutStoreFactory` (launch-time fixture injection) |
| `WorkoutFixturesTestSupport` | Apple + Linux | Bundled presets, `InMemoryWorkoutStore`, `RecordingWorkoutSink`, `FailingWorkoutSource` |
| `WorkoutFixturesDebugUI` | iOS/macOS | Drop-in `WorkoutFixtureDebugView` debug panel (capture/export/import/replay) for any HealthKit-entitled app |
| `workout-fixture` (CLI) | Apple + Linux | inspect, validate, split, redact, generate, migrate, import-gpx, schema |

The example host app (`Examples/WorkoutFixturesHost`) is a thin shell around
`WorkoutFixtureDebugView` plus the HealthKit entitlement; it exists as the
reference integration and the runnable target for UI/integration tests.

## Commands (use these, not raw invocations)

```bash
make test        # portable package tests (swift test, xcsift-piped when installed)
make test-host   # host app unit + UI tests on a simulator
make lint        # swift format lint --strict (matches the CI lint job)
make format      # swift format --in-place
make smoke       # CLI generate → validate → inspect round trip
```

## Invariants (do not break these)

- **Strict decoding**: fixture, archive, and recipe JSON reject unknown fields.
  Never decode these types with a bare `JSONDecoder` — use `FixtureJSONCodec`,
  `FixtureArchiveJSONCodec`, `GenerationRecipeCodec`, or `JSONWorkoutSource`.
- **Determinism**: all randomness flows from an explicit `seed: UInt64`
  (generation, redaction). Never introduce `Date()`, `UUID()`, or unseeded
  randomness into generated/redacted data paths. Tests use seed 42.
- **Derived summaries**: totals are always computed from sample timelines
  (`WorkoutSummary(fixture:)`), never stored. Do not add stored totals.
- **Privacy**: redacted output must never reveal the redaction seed or original
  dates/route/source metadata (see `Redaction.swift`; there is a test for the
  seed leak).
- **Concurrency**: Swift 6 language mode, `StrictConcurrency=complete`,
  `NonisolatedNonsendingByDefault`. Fix isolation errors properly — never add
  `@unchecked Sendable`, `nonisolated(unsafe)`, semaphores, or `DispatchQueue`.
  `@MainActor` belongs only in `WorkoutFixturesDebugUI` and the host app.
- **Schema stability**: `Sources/WorkoutFixtures/Resources/*.schema.json`
  mirror the Swift wire format. Changing the fixture wire format requires a
  `SchemaVersion` bump plus schema + `StrictFixtureFields` updates together.
- **Linux**: `WorkoutFixtures`, `WorkoutFixturesTestSupport`, and the CLI must
  keep building on Linux (CI enforces). Gate Apple-only code behind
  `#if canImport(HealthKit)` / `canImport(SwiftUI)`.

## JSON Schemas

- Files: `Sources/WorkoutFixtures/Resources/{WorkoutFixture,WorkoutFixtureArchive,GenerationRecipe}.schema.json`
- Programmatic: `FixtureJSONCodec.schemaData`, `FixtureArchiveJSONCodec.schemaData`, `GenerationRecipeCodec.schemaData`
- CLI: `swift run workout-fixture schema fixture|archive|recipe`

## CLI contract

- stdout carries payloads and confirmations; stderr carries diagnostics.
- `--diagnostics-format json` emits NDJSON: one
  `{"severity","code","path","message"}` object per line.
- Exit codes: `0` success, `1` validation/operational failure, `64` usage error
  (asserted by `Tests/WorkoutFixtureCLITests/CommandRunTests.swift`).
- `inspect --json` wraps output as `{"kind":"fixture","summary":{...}}` or
  `{"kind":"archive","createdAt":...,"fixtures":[...]}`.

## Testing conventions

- Swift Testing (`@Suite`/`@Test`, `#expect`/`try #require`) everywhere except
  XCUITest. Parameterize with `@Test(arguments:)` instead of repeating tests.
- Tests are parallel-safe: value types, no globals, temp files under
  `FileManager.default.temporaryDirectory` with `UUID()` names and cleanup.
- Test doubles live in `WorkoutFixturesTestSupport` (`InMemoryWorkoutStore`,
  `RecordingWorkoutSink`, `FailingWorkoutSource`) — use them instead of
  constructing `HKHealthStore` in unit tests.
- The HealthKit round-trip suite (`HealthKitIntegrationTests`) only runs when
  `WORKOUT_FIXTURES_HEALTHKIT_INTEGRATION=1` reaches the test process
  (CI passes it as `TEST_RUNNER_…`); it needs a manually pre-authorized
  simulator. Don't try to automate the authorization modal — it can't be.

## Launch-time fixture injection

Apps wire dependencies once through `WorkoutStoreFactory.make(...)`; UI tests
then select fixtures with `app.launchEnvironment["WORKOUT_FIXTURES_MODE"] =
"presets"` (or `json` + `WORKOUT_FIXTURES_PATH`, `resource` +
`WORKOUT_FIXTURES_RESOURCE`). Parsing lives in `FixtureLaunchConfiguration`.

## Gotchas

- Package resources load via `Bundle.module`; preset fixtures live in
  `Sources/WorkoutFixturesTestSupport/Resources/Fixtures/`.
- `Examples/focused-recipe.json` is exercised by CommandRunTests — keep it
  valid when editing.
- The pbxproj uses hand-maintained synthetic IDs (`1…`, `2…`, `E…`); follow the
  existing pattern when adding files to the host project.
- CI (`.github/workflows/ci.yml`): lint + Linux tests + CLI smoke + macOS
  package/host tests. The signing guard fails the build if a
  `DEVELOPMENT_TEAM` is committed to the host project — never commit one.
