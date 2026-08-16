import Foundation

public enum UnknownFieldPolicy: String, Codable, Sendable {
  case reject
  case ignore
}

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

public struct FixtureJSONCodec: Sendable {
  public init() {}

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

  public func encode(_ fixture: WorkoutFixture) throws -> Data {
    guard fixture.schemaVersion == .current else {
      throw FixtureCodingError.unsupportedSchemaVersion(fixture.schemaVersion)
    }
    return try CanonicalFixtureJSON.encode(fixture)
  }

  public func migrate(_ data: Data) throws -> Data {
    try encode(decode(data, unknownFields: .reject))
  }

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

  static func encode<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
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
    "schemaVersion", "id", "workout", "series", "events", "route", "provenance",
  ]
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
