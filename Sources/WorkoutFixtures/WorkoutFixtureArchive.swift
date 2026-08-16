import Foundation

public enum FixtureArchiveCodingError: Error, Equatable, Sendable, LocalizedError {
  case invalidTopLevel
  case unknownField(path: String)
  case missingSchemaVersion
  case unsupportedSchemaVersion(SchemaVersion)
  case missingFixtureSchemaVersion(index: Int)
  case unsupportedFixtureSchemaVersion(index: Int, version: SchemaVersion)
  case duplicateFixtureID(WorkoutID)

  public var errorDescription: String? {
    switch self {
    case .invalidTopLevel:
      "The fixture archive must be a JSON object."
    case .unknownField(let path):
      "Unknown fixture archive field at '\(path)'."
    case .missingSchemaVersion:
      "The fixture archive does not declare schemaVersion."
    case .unsupportedSchemaVersion(let version):
      "Unsupported fixture archive schema version \(version.rawValue)."
    case .missingFixtureSchemaVersion(let index):
      "Fixture at index \(index) does not declare schemaVersion."
    case .unsupportedFixtureSchemaVersion(let index, let version):
      "Fixture at index \(index) uses unsupported schema version \(version.rawValue)."
    case .duplicateFixtureID(let id):
      "Fixture archive contains duplicate workout ID '\(id.rawValue)'."
    }
  }
}

public struct WorkoutFixtureArchive: Codable, Equatable, Sendable {
  public let schemaVersion: SchemaVersion
  public let createdAt: Date
  public let fixtures: [WorkoutFixture]

  public init(
    schemaVersion: SchemaVersion = .current,
    createdAt: Date = Date(),
    fixtures: [WorkoutFixture]
  ) throws {
    guard schemaVersion == .current else {
      throw FixtureArchiveCodingError.unsupportedSchemaVersion(schemaVersion)
    }
    if let unsupported = fixtures.enumerated().first(where: {
      $0.element.schemaVersion != .current
    }) {
      throw FixtureArchiveCodingError.unsupportedFixtureSchemaVersion(
        index: unsupported.offset,
        version: unsupported.element.schemaVersion
      )
    }
    if let duplicateID = Self.firstDuplicateID(in: fixtures) {
      throw FixtureArchiveCodingError.duplicateFixtureID(duplicateID)
    }
    self.schemaVersion = schemaVersion
    self.createdAt = createdAt
    self.fixtures = fixtures
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      schemaVersion: container.decode(SchemaVersion.self, forKey: .schemaVersion),
      createdAt: container.decode(Date.self, forKey: .createdAt),
      fixtures: container.decode([WorkoutFixture].self, forKey: .fixtures)
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(fixtures, forKey: .fixtures)
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case createdAt
    case fixtures
  }

  private static func firstDuplicateID(in fixtures: [WorkoutFixture]) -> WorkoutID? {
    var ids: Set<WorkoutID> = []
    return fixtures.first { !ids.insert($0.id).inserted }?.id
  }
}

public struct FixtureArchiveJSONCodec: Sendable {
  public init() {}

  public func decode(
    _ data: Data,
    unknownFields: UnknownFieldPolicy = .reject
  ) throws -> WorkoutFixtureArchive {
    let raw = try JSONSerialization.jsonObject(with: data)
    guard let object = raw as? [String: Any] else {
      throw FixtureArchiveCodingError.invalidTopLevel
    }
    return try decode(data, rootObject: object, unknownFields: unknownFields)
  }

  func decode(
    _ data: Data,
    rootObject object: [String: Any],
    unknownFields: UnknownFieldPolicy
  ) throws -> WorkoutFixtureArchive {
    guard let rawVersion = object["schemaVersion"] as? Int else {
      throw FixtureArchiveCodingError.missingSchemaVersion
    }
    let version = SchemaVersion(rawValue: rawVersion)
    guard version == .current else {
      throw FixtureArchiveCodingError.unsupportedSchemaVersion(version)
    }

    if unknownFields == .reject {
      let allowedArchiveFields: Set<String> = ["schemaVersion", "createdAt", "fixtures"]
      if let field = object.keys.sorted().first(where: { !allowedArchiveFields.contains($0) }) {
        throw FixtureArchiveCodingError.unknownField(path: field)
      }
    }

    if let fixtures = object["fixtures"] as? [[String: Any]] {
      for (index, fixture) in fixtures.enumerated() {
        guard let rawFixtureVersion = fixture["schemaVersion"] as? Int else {
          throw FixtureArchiveCodingError.missingFixtureSchemaVersion(index: index)
        }
        let fixtureVersion = SchemaVersion(rawValue: rawFixtureVersion)
        guard fixtureVersion == .current else {
          throw FixtureArchiveCodingError.unsupportedFixtureSchemaVersion(
            index: index,
            version: fixtureVersion
          )
        }
        if unknownFields == .reject,
          let path = StrictFixtureFields.firstUnknownField(in: fixture)
        {
          throw FixtureArchiveCodingError.unknownField(path: "fixtures[\(index)].\(path)")
        }
      }
    }

    return try CanonicalFixtureJSON.makeDecoder().decode(WorkoutFixtureArchive.self, from: data)
  }

  public func encode(_ archive: WorkoutFixtureArchive) throws -> Data {
    guard archive.schemaVersion == .current else {
      throw FixtureArchiveCodingError.unsupportedSchemaVersion(archive.schemaVersion)
    }
    return try CanonicalFixtureJSON.encode(archive)
  }

  public static var schemaData: Data {
    get throws {
      guard
        let url = Bundle.module.url(
          forResource: "WorkoutFixtureArchive.schema",
          withExtension: "json"
        )
      else {
        throw CocoaError(.fileNoSuchFile)
      }
      return try Data(contentsOf: url)
    }
  }
}
