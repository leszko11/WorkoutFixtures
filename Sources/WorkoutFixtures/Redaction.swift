import Foundation

/// Selects which privacy transformations ``WorkoutRedactor`` applies.
public struct RedactionPolicy: Codable, Equatable, Sendable {
  /// Replace the fixture ID with an opaque token that cannot be traced back to the original ID
  /// (a one-way mix of the redaction seed and the original ID).
  public let regenerateID: Bool
  /// Drop the GPS route entirely; location traces are the most identifying data a workout has.
  public let removeRoute: Bool
  /// Drop the recording app/device metadata from provenance.
  public let removeSourceMetadata: Bool
  /// Shift every date by a seed-derived whole number of calendar days (30–365, in either
  /// direction) so the workout no longer reveals when it really happened.
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

  /// The policy for fixtures leaving the device they were captured on: regenerates the ID,
  /// removes the route and source metadata, and shifts all dates.
  public static let sharing = Self(
    regenerateID: true,
    removeRoute: true,
    removeSourceMetadata: true,
    shiftDates: true
  )
}

/// Produces privacy-safe copies of captured fixtures for sharing.
///
/// Redaction is deterministic — the same seed and fixture always produce the same output — and
/// one-way: the output never contains the seed, its provenance is reset to
/// ``ProvenanceKind/redacted`` with no source fixture reference, and the regenerated ID cannot
/// be reversed into the original ID or the seed.
public struct WorkoutRedactor: Sendable {
  public init() {}

  /// Returns a redacted copy of `fixture` according to `policy`.
  ///
  /// With the default ``RedactionPolicy/sharing`` policy the result has a regenerated ID, no
  /// route, no source metadata, and every date shifted by a seed-derived number of calendar
  /// days (computed in the workout's own time zone, so the local time of day is preserved).
  /// The provenance `createdAt` is set to the shifted workout start so the real capture time
  /// does not leak.
  /// - Throws: ``GenerationError/dateCalculationFailed`` when the fixture's time zone
  ///   identifier is invalid or the calendar shift cannot be computed.
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
