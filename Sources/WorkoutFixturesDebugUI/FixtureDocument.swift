#if canImport(SwiftUI) && canImport(HealthKit) && !os(watchOS)
  import SwiftUI
  import UniformTypeIdentifiers
  import WorkoutFixtures

  /// A `FileDocument` wrapping canonical fixture or archive JSON for the
  /// system exporter and importer.
  public struct FixtureDocument: FileDocument, Sendable {
    public static var readableContentTypes: [UTType] { [.json] }

    public let data: Data

    public init(fixture: WorkoutFixture) throws {
      data = try FixtureJSONCodec().encode(fixture)
    }

    public init(archive: WorkoutFixtureArchive) throws {
      data = try FixtureArchiveJSONCodec().encode(archive)
    }

    public init(configuration: ReadConfiguration) throws {
      try self.init(fileWrapper: configuration.file)
    }

    init(fileWrapper: FileWrapper) throws {
      guard let data = fileWrapper.regularFileContents else {
        throw CocoaError(.fileReadCorruptFile)
      }
      self.data = data
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
      FileWrapper(regularFileWithContents: data)
    }
  }
#endif
