#if canImport(SwiftUI) && canImport(HealthKit) && !os(watchOS)
  import SwiftUI
  import UniformTypeIdentifiers
  import WorkoutFixtures

  /// A `FileDocument` wrapping gzip-compressed, compact fixture or archive JSON.
  public struct FixtureDocument: FileDocument, Sendable {
    public static var readableContentTypes: [UTType] { [.json, .gzip] }

    public let data: Data

    public init(fixture: WorkoutFixture) throws {
      let json = try FixtureJSONCodec().encode(fixture, formatting: .compact)
      try Task.checkCancellation()
      data = try GzipCodec.compress(json)
    }

    public init(archive: WorkoutFixtureArchive) throws {
      let json = try FixtureArchiveJSONCodec().encode(archive, formatting: .compact)
      try Task.checkCancellation()
      data = try GzipCodec.compress(json)
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
