# The Fixture Format

Schema v1: strict, canonical, and portable JSON.

## Shape

A fixture is one workout: descriptor (activity, location, start/end, IANA time
zone), canonical metric series (`heartRate` in `count/min`, `distance` in `m`,
`activeEnergy` in `kcal`), events (pause/resume/lap/segment/marker), an
optional GPS route, and provenance (captured, generated, authored, or
redacted). An archive wraps many fixtures plus a creation date.

Summaries are always derived from the sample timeline
(``WorkoutSummary/init(fixture:)``), so stored totals can never disagree with
the data.

## Strictness

- Timestamps are ISO-8601 UTC with fractional seconds.
- Decoding rejects unknown fields and future schema versions by default;
  ``UnknownFieldPolicy/ignore`` is an explicit recovery mode.
- ``WorkoutValidator`` returns stable issue codes and JSON paths; errors block
  generation and HealthKit writes, warnings preserve unusual but representable
  data.

Never decode fixture, archive, or recipe JSON with a bare `JSONDecoder` — the
strict codecs are the contract.

## Published JSON Schemas

Draft 2020-12 schemas ship in the module and mirror the wire format:

- ``FixtureJSONCodec/schemaData``
- ``FixtureArchiveJSONCodec/schemaData``
- ``GenerationRecipeCodec/schemaData``

Or from the CLI: `workout-fixture schema fixture|archive|recipe`.

## Versioning

`schemaVersion` is `1` everywhere today. Changing the wire format requires a
version bump plus coordinated updates to the schemas and the strict field
lists.
