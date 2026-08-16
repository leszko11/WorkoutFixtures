import SwiftUI
import UniformTypeIdentifiers
import WorkoutFixtures

struct FixtureDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }

  let data: Data

  init(fixture: WorkoutFixture) throws {
    data = try FixtureJSONCodec().encode(fixture)
  }

  init(archive: WorkoutFixtureArchive) throws {
    data = try FixtureArchiveJSONCodec().encode(archive)
  }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    self.data = data
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
