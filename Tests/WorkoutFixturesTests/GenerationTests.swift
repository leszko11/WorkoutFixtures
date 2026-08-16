import Foundation
import Testing
import WorkoutFixtures
import WorkoutFixturesTestSupport

@Suite("Deterministic generation")
struct GenerationTests {
  private let recipe = GenerationRecipe(transforms: [
    .shiftDate(days: IntegerRange(7...21)),
    .scaleDuration(DoubleRange(0.9...1.1)),
    .scaleMetric(.distance, factor: DoubleRange(0.95...1.05)),
    .addNoise(to: .heartRate, standardDeviation: 3, bounds: 35...210),
    .resample(.heartRate, every: 120),
    .translateRoute(to: Coordinate(latitude: 50.0614, longitude: 19.9366)),
    .rotateRoute(degrees: 15),
    .jitterRoute(maxMeters: 4),
  ])

  @Test("Same seed produces identical fixture")
  func sameSeedIsIdentical() async throws {
    let template = try WorkoutFixturePreset.outdoorRun.fixture()
    let generator = TemplateWorkoutGenerator()
    async let first = generator.generate(from: template, recipe: recipe, seed: 42)
    async let second = generator.generate(from: template, recipe: recipe, seed: 42)
    #expect(try await first == second)
  }

  @Test("Different seeds produce different fixture")
  func differentSeedsDiverge() async throws {
    let template = try WorkoutFixturePreset.outdoorRun.fixture()
    let generator = TemplateWorkoutGenerator()
    let first = try await generator.generate(from: template, recipe: recipe, seed: 1)
    let second = try await generator.generate(from: template, recipe: recipe, seed: 2)
    #expect(first != second)
  }

  @Test("Parallel batches retain deterministic index order")
  func batchOrderIsStable() async throws {
    let template = try WorkoutFixturePreset.outdoorRun.fixture()
    let generator = TemplateWorkoutGenerator()
    let first = try await generator.generate(count: 12, from: template, recipe: recipe, seed: 99)
    let second = try await generator.generate(count: 12, from: template, recipe: recipe, seed: 99)
    #expect(first == second)
    #expect(Set(first.map(\.id)).count == 12)
  }

  @Test("Duration scaling transforms the complete timeline")
  func durationScaling() async throws {
    let template = try WorkoutFixturePreset.outdoorRun.fixture()
    let generated = try await TemplateWorkoutGenerator().generate(
      from: template,
      recipe: GenerationRecipe(transforms: [.scaleDuration(DoubleRange(0.5))]),
      seed: 7
    )
    #expect(generated.summary.elapsedDuration == template.summary.elapsedDuration / 2)
    #expect(generated.route?.points.last?.date == generated.workout.endDate)
    #expect(
      generated.series.flatMap(\.samples).allSatisfy {
        $0.startDate >= generated.workout.startDate && $0.endDate <= generated.workout.endDate
      })
  }

  @Test("Cumulative metric resampling preserves totals")
  func resamplingPreservesDistance() async throws {
    let template = try WorkoutFixturePreset.outdoorRun.fixture()
    let generated = try await TemplateWorkoutGenerator().generate(
      from: template,
      recipe: GenerationRecipe(transforms: [.resample(.distance, every: 300)]),
      seed: 7
    )
    let original = try #require(template.total(for: .distance))
    let result = try #require(generated.total(for: .distance))
    #expect(abs(original - result) < 0.000_001)
  }

  @Test("Metric scaling applies one coherent factor to the complete series")
  func metricScalingIsCoherent() async throws {
    let template = try WorkoutFixturePreset.outdoorRun.fixture()
    let generated = try await TemplateWorkoutGenerator().generate(
      from: template,
      recipe: GenerationRecipe(transforms: [
        .scaleMetric(.distance, factor: DoubleRange(0.5...1.5))
      ]),
      seed: 42
    )
    let original = try #require(template.series(for: .distance)?.samples)
    let scaled = try #require(generated.series(for: .distance)?.samples)
    let firstPair = try #require(zip(original, scaled).first(where: { _ in true }))
    let factor = firstPair.1.value / firstPair.0.value

    #expect(
      zip(original, scaled).allSatisfy {
        abs(($0.1.value / $0.0.value) - factor) < 0.000_001
      })
  }

  @Test("Invalid transforms fail at decode time")
  func invalidTransformsFailDecoding() {
    let payloads = [
      #"{"kind": "scaleMetric"}"#,
      #"{"kind": "warpTime"}"#,
      #"{"kind": "addNoise", "metric": "heartRate", "standardDeviation": 3, "minimum": 10}"#,
    ]
    for payload in payloads {
      #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(GenerationTransform.self, from: Data(payload.utf8))
      }
    }
  }

  @Test("Encoded transforms use the legacy flat field names")
  func wireFormatUsesLegacyFieldNames() throws {
    let expectations: [(GenerationTransform, Set<String>)] = [
      (.shiftDate(days: IntegerRange(7...21)), ["kind", "integerRange"]),
      (.scaleDuration(DoubleRange(0.9...1.1)), ["kind", "valueRange"]),
      (
        .scaleMetric(.distance, factor: DoubleRange(0.95...1.05)),
        ["kind", "metric", "valueRange"]
      ),
      (
        .addNoise(to: .heartRate, standardDeviation: 3, bounds: 35...210),
        ["kind", "metric", "standardDeviation", "minimum", "maximum"]
      ),
      (
        .addNoise(to: .heartRate, standardDeviation: 3, bounds: nil),
        ["kind", "metric", "standardDeviation"]
      ),
      (.resample(.heartRate, every: 120), ["kind", "metric", "intervalSeconds"]),
      (
        .translateRoute(to: Coordinate(latitude: 50.0614, longitude: 19.9366)),
        ["kind", "coordinate"]
      ),
      (.rotateRoute(degrees: 15), ["kind", "degrees"]),
      (.jitterRoute(maxMeters: 4), ["kind", "maxMeters"]),
      (.removeRoute, ["kind"]),
    ]
    for (transform, expectedKeys) in expectations {
      let encoded = try JSONEncoder().encode(transform)
      let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
      #expect(Set(object.keys) == expectedKeys)
      #expect(try JSONDecoder().decode(GenerationTransform.self, from: encoded) == transform)
    }
  }

  @Test("Cancellation is observed before work begins")
  func cancellation() async throws {
    let template = try WorkoutFixturePreset.outdoorRun.fixture()
    let task = Task {
      try await TemplateWorkoutGenerator().generate(
        from: template,
        recipe: recipe,
        seed: 42
      )
    }
    task.cancel()
    await #expect(throws: CancellationError.self) {
      try await task.value
    }
  }
}
