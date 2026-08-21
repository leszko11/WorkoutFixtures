# ``WorkoutFixtures``

Portable, deterministic workout fixtures for testing HealthKit apps.

## Overview

WorkoutFixtures models the workout data — not `HKHealthStore` — so the same
fixture works in unit tests, SwiftUI previews, command-line tools, Linux CI,
and HealthKit integration tests.

The core loop:

1. **Capture** real workouts on a device (with the embeddable debug panel or
   the example host app) into a portable JSON archive.
2. **Sanitize** fixtures with deterministic redaction before sharing.
3. **Generate** seeded variations from a template, or import GPX tracks.
4. **Replay** fixtures through `any WorkoutFixtureSource` in tests and
   previews — or write them into simulator HealthKit when the real adapter
   must be exercised.

## Topics

### Essentials

- <doc:InstallationAndUsage>
- <doc:IntegratingHealthKitFacade>
- ``WorkoutFixture``
- ``WorkoutFixtureSource``
- ``WorkoutFixtureSink``
- ``WorkoutFixtureDeleting``
- ``FixtureWorkoutStore``

### Fixture data

- <doc:TheFixtureFormat>
- ``WorkoutSummary``
- ``WorkoutElevation``
- ``WorkoutQuery``
- ``FixtureJSONCodec``
- ``FixtureArchiveJSONCodec``
- ``WorkoutValidator``
- ``WorkoutHistoryDocument``

### Capture and privacy

- <doc:CapturingRealWorkouts>
- ``WorkoutFixtureCaptureOptions``
- ``WorkoutRedactor``
- ``RedactionPolicy``

### Generation and import

- ``TemplateWorkoutGenerator``
- ``GenerationRecipe``
- ``GenerationTransform``
- ``GPXWorkoutImporter``

### Injection

- ``InMemoryWorkoutSource``
- ``JSONWorkoutSource``
- ``FixtureLaunchConfiguration``
- ``FixtureMerger``
