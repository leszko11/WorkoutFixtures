import Foundation

/// Stable output styles for fixture and archive JSON.
public enum FixtureJSONFormatting: Equatable, Sendable {
  /// Human-readable JSON matching the package's existing canonical wire representation.
  case canonical
  /// Sorted, deterministic JSON without insignificant whitespace.
  case compact
}

/// How decoding treats JSON fields the fixture schema does not define.
public enum UnknownFieldPolicy: String, Codable, Sendable {
  /// Fail decoding, naming the first unknown field; the default, so typos surface immediately.
  case reject
  /// Silently skip unknown fields; use for reading data from newer producers.
  case ignore
}

/// Failures raised while decoding or encoding a single fixture document.
public enum FixtureCodingError: Error, Equatable, Sendable, LocalizedError {
  case invalidTopLevel
  case unknownField(path: String)
  case unsupportedSchemaVersion(SchemaVersion)
  case missingSchemaVersion

  public var errorDescription: String? {
    switch self {
    case .invalidTopLevel:
      "The fixture must be a JSON object."
    case .unknownField(let path):
      "Unknown fixture field at '\(path)'."
    case .unsupportedSchemaVersion(let version):
      "Unsupported fixture schema version \(version.rawValue)."
    case .missingSchemaVersion:
      "The fixture does not declare schemaVersion."
    }
  }
}

/// Decodes and encodes single ``WorkoutFixture`` documents as strict, canonical JSON.
///
/// Decoding requires a top-level JSON object that declares the current `schemaVersion`, and
/// with the default ``UnknownFieldPolicy/reject`` policy fails on any field the schema does
/// not define. Encoding is canonical — pretty-printed with sorted keys, a trailing newline,
/// and ISO-8601 UTC timestamps with fractional seconds — so equal fixtures always encode to
/// byte-identical output, which keeps fixtures diffable in version control.
public struct FixtureJSONCodec: Sendable {
  public init() {}

  /// Decodes one fixture from `data`.
  /// - Throws: ``FixtureCodingError`` when the top level is not an object, `schemaVersion` is
  ///   missing or unsupported, or (under ``UnknownFieldPolicy/reject``) an unknown field is
  ///   present; `DecodingError` for malformed values, including timestamps that are not
  ///   ISO-8601 with fractional seconds.
  public func decode(
    _ data: Data,
    unknownFields: UnknownFieldPolicy = .reject
  ) throws -> WorkoutFixture {
    let raw = try JSONSerialization.jsonObject(with: data)
    guard let object = raw as? [String: Any] else {
      throw FixtureCodingError.invalidTopLevel
    }
    return try decode(data, rootObject: object, unknownFields: unknownFields)
  }

  func decode(
    _ data: Data,
    rootObject object: [String: Any],
    unknownFields: UnknownFieldPolicy
  ) throws -> WorkoutFixture {
    guard let rawVersion = object["schemaVersion"] as? Int else {
      throw FixtureCodingError.missingSchemaVersion
    }
    let version = SchemaVersion(rawValue: rawVersion)
    guard version == .current else {
      throw FixtureCodingError.unsupportedSchemaVersion(version)
    }
    if unknownFields == .reject, let path = StrictFixtureFields.firstUnknownField(in: object) {
      throw FixtureCodingError.unknownField(path: path)
    }

    return try CanonicalFixtureJSON.makeDecoder().decode(WorkoutFixture.self, from: data)
  }

  /// Encodes `fixture` to canonical JSON (pretty, sorted keys, trailing newline, ISO-8601 UTC
  /// dates with fractional seconds).
  /// - Throws: ``FixtureCodingError/unsupportedSchemaVersion(_:)`` when the fixture's schema
  ///   version is not ``SchemaVersion/current``.
  public func encode(
    _ fixture: WorkoutFixture,
    formatting: FixtureJSONFormatting = .canonical
  ) throws -> Data {
    guard fixture.schemaVersion == .current else {
      throw FixtureCodingError.unsupportedSchemaVersion(fixture.schemaVersion)
    }
    return try CanonicalFixtureJSON.encode(fixture, formatting: formatting)
  }

  /// Rewrites fixture JSON into the current schema: lifts migratable versions, then
  /// canonicalizes so the result is byte-stable regardless of the input's formatting.
  public func migrate(_ data: Data) throws -> Data {
    try encode(decodeMigrating(data))
  }

  /// Decodes fixtures written at any ``SchemaVersion/migratable`` version and rewrites them
  /// to ``SchemaVersion/current``.
  public func decodeMigrating(
    _ data: Data,
    unknownFields: UnknownFieldPolicy = .reject
  ) throws -> WorkoutFixture {
    guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw FixtureCodingError.invalidTopLevel
    }
    guard let rawVersion = object["schemaVersion"] as? Int else {
      throw FixtureCodingError.missingSchemaVersion
    }
    let version = SchemaVersion(rawValue: rawVersion)
    guard SchemaVersion.migratable.contains(version) else {
      throw FixtureCodingError.unsupportedSchemaVersion(version)
    }
    if version != .current {
      object["schemaVersion"] = SchemaVersion.current.rawValue
    }
    let rewritten = try JSONSerialization.data(withJSONObject: object)
    var fixture = try decode(rewritten, unknownFields: unknownFields)
    if fixture.schemaVersion != .current {
      fixture = WorkoutFixture(
        schemaVersion: .current,
        id: fixture.id,
        workout: fixture.workout,
        series: fixture.series,
        events: fixture.events,
        route: fixture.route,
        elevation: fixture.elevation,
        provenance: fixture.provenance
      )
    }
    return fixture
  }

  /// The bundled JSON Schema describing the single-fixture document format, for external
  /// validation tooling.
  public static var schemaData: Data {
    get throws {
      guard
        let url = Bundle.module.url(
          forResource: "WorkoutFixture.schema",
          withExtension: "json"
        )
      else {
        throw CocoaError(.fileNoSuchFile)
      }
      return try Data(contentsOf: url)
    }
  }
}

enum CanonicalFixtureJSON {
  static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      guard let date = makeDateFormatter().date(from: value) else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "Expected an ISO-8601 timestamp with fractional seconds."
        )
      }
      return date
    }
    return decoder
  }

  static func encode<Value: Encodable>(
    _ value: Value,
    formatting: FixtureJSONFormatting = .canonical
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    if formatting == .canonical {
      encoder.outputFormatting.insert(.prettyPrinted)
    }
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(makeDateFormatter().string(from: date))
    }
    var data = try encoder.encode(value)
    data.append(0x0A)
    return data
  }

  // Constructed per call: ISO8601DateFormatter is not documented thread-safe, and
  // `Date.ISO8601FormatStyle` is not byte-compatible with this configuration (it truncates
  // instead of rounding fractional milliseconds on output and accepts timestamps without
  // fractional seconds on input), so a cached Sendable style cannot replace it.
  private static func makeDateFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [
      .withInternetDateTime,
      .withFractionalSeconds,
      .withColonSeparatorInTimeZone,
    ]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }
}

enum StrictFixtureFields {
  static func firstUnknownField(in root: [String: Any]) -> String? {
    if let field = unknown(in: root, allowed: rootKeys) { return field }
    if let workout = root["workout"] as? [String: Any],
      let field = unknown(in: workout, allowed: workoutKeys)
    {
      return "workout.\(field)"
    }
    if let series = root["series"] as? [[String: Any]] {
      for (seriesIndex, item) in series.enumerated() {
        if let field = unknown(in: item, allowed: seriesKeys) {
          return "series[\(seriesIndex)].\(field)"
        }
        if let samples = item["samples"] as? [[String: Any]] {
          for (sampleIndex, sample) in samples.enumerated() {
            if let field = unknown(in: sample, allowed: sampleKeys) {
              return "series[\(seriesIndex)].samples[\(sampleIndex)].\(field)"
            }
          }
        }
      }
    }
    if let events = root["events"] as? [[String: Any]] {
      for (index, event) in events.enumerated() {
        if let field = unknown(in: event, allowed: eventKeys) {
          return "events[\(index)].\(field)"
        }
      }
    }
    if let route = root["route"] as? [String: Any] {
      if let field = unknown(in: route, allowed: routeKeys) { return "route.\(field)" }
      if let points = route["points"] as? [[String: Any]] {
        for (index, point) in points.enumerated() {
          if let field = unknown(in: point, allowed: routePointKeys) {
            return "route.points[\(index)].\(field)"
          }
        }
      }
    }
    if let elevation = root["elevation"] as? [String: Any],
      let field = unknown(in: elevation, allowed: elevationKeys)
    {
      return "elevation.\(field)"
    }
    if let provenance = root["provenance"] as? [String: Any] {
      if let field = unknown(in: provenance, allowed: provenanceKeys) {
        return "provenance.\(field)"
      }
      if let source = provenance["source"] as? [String: Any],
        let field = unknown(in: source, allowed: sourceKeys)
      {
        return "provenance.source.\(field)"
      }
    }
    return nil
  }

  private static func unknown(in object: [String: Any], allowed: Set<String>) -> String? {
    object.keys.sorted().first { !allowed.contains($0) }
  }

  private static let rootKeys: Set<String> = [
    "schemaVersion", "id", "workout", "series", "events", "route", "elevation", "provenance",
  ]
  private static let elevationKeys: Set<String> = ["ascentMeters", "descentMeters"]
  private static let workoutKeys: Set<String> = [
    "activity", "location", "startDate", "endDate", "timeZoneIdentifier",
  ]
  private static let seriesKeys: Set<String> = ["metric", "unit", "samples"]
  private static let sampleKeys: Set<String> = ["startDate", "endDate", "value"]
  private static let eventKeys: Set<String> = ["kind", "startDate", "endDate"]
  private static let routeKeys: Set<String> = ["points"]
  private static let routePointKeys: Set<String> = [
    "date", "latitude", "longitude", "altitude", "horizontalAccuracy",
    "verticalAccuracy", "speed", "course",
  ]
  private static let provenanceKeys: Set<String> = [
    "kind", "createdAt", "sourceFixtureID", "generatorVersion", "seed", "source",
  ]
  private static let sourceKeys: Set<String> = [
    "name", "bundleIdentifier", "version", "deviceModel",
  ]
}
