import Foundation

public struct RedactionPolicy: Codable, Equatable, Sendable {
  public let regenerateID: Bool
  public let removeRoute: Bool
  public let removeSourceMetadata: Bool
  public let shiftDates: Bool

  public init(
    regenerateID: Bool,
    removeRoute: Bool,
    removeSourceMetadata: Bool,
    shiftDates: Bool
  ) {
    self.regenerateID = regenerateID
    self.removeRoute = removeRoute
    self.removeSourceMetadata = removeSourceMetadata
    self.shiftDates = shiftDates
  }

  public static let sharing = Self(
    regenerateID: true,
    removeRoute: true,
    removeSourceMetadata: true,
    shiftDates: true
  )
}

public struct WorkoutRedactor: Sendable {
  public init() {}

  public func redact(
    _ fixture: WorkoutFixture,
    using policy: RedactionPolicy = .sharing,
    seed: UInt64
  ) throws -> WorkoutFixture {
    let shifted: WorkoutFixture
    if policy.shiftDates {
      let magnitude = Int(seed % 336) + 30
      let direction = seed & 1 == 0 ? 1 : -1
      shifted = try fixture.shiftingDates(
        byDays: magnitude * direction,
        shiftProvenanceCreatedAt: false
      )
    } else {
      shifted = fixture
    }
    return WorkoutFixture(
      id: policy.regenerateID
        ? WorkoutID(rawValue: "redacted-\(Self.opaqueToken(seed: seed, id: fixture.id))")
        : shifted.id,
      workout: shifted.workout,
      series: shifted.series,
      events: shifted.events,
      route: policy.removeRoute ? nil : shifted.route,
      provenance: FixtureProvenance(
        kind: .redacted,
        createdAt: shifted.workout.startDate,
        sourceFixtureID: nil,
        generatorVersion: TemplateWorkoutGenerator.generatorVersion,
        seed: nil,
        source: policy.removeSourceMetadata ? nil : shifted.provenance.source
      )
    )
  }

  // The date shift is derived from the seed, so the output must not reveal the
  // seed (or the shift is reversible). Mixing the seed with the discarded
  // original identifier makes the emitted token one-way.
  private static func opaqueToken(seed: UInt64, id: WorkoutID) -> String {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in id.rawValue.utf8 {
      hash ^= UInt64(byte)
      hash &*= 0x0000_0100_0000_01B3
    }
    var random = SplitMix64(seed: seed ^ hash)
    return String(random.next(), radix: 16)
  }
}
