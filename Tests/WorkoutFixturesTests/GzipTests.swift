import Foundation
import Testing
import WorkoutFixtures
import WorkoutFixturesTestSupport

@Suite("Gzip transport encoding")
struct GzipTests {
  @Test("Compression round-trips arbitrary payloads")
  func roundTrip() throws {
    let payload = Data(String(repeating: "workout fixtures ", count: 1_000).utf8)
    let compressed = try GzipCodec.compress(payload)
    #expect(GzipCodec.isGzipped(compressed))
    #expect(compressed.count < payload.count)
    #expect(try GzipCodec.decompress(compressed) == payload)
  }

  @Test("Plain and empty data are not detected as gzip")
  func magicDetection() throws {
    #expect(!GzipCodec.isGzipped(Data()))
    #expect(!GzipCodec.isGzipped(Data("{}".utf8)))
    #expect(!GzipCodec.isGzipped(Data([0x1f])))
  }

  @Test("Corrupt gzip data produces a typed error")
  func corruptData() throws {
    var corrupted = Data([0x1f, 0x8b])
    corrupted.append(Data(String(repeating: "x", count: 64).utf8))
    #expect(throws: GzipCodingError.corruptedData) {
      try GzipCodec.decompress(corrupted)
    }
  }

  @Test("Truncated gzip data produces a typed error")
  func truncatedData() throws {
    let compressed = try GzipCodec.compress(
      Data(String(repeating: "workout fixtures ", count: 1_000).utf8))
    let truncated = compressed.prefix(compressed.count / 2)
    #expect(throws: GzipCodingError.truncatedData) {
      try GzipCodec.decompress(Data(truncated))
    }
  }

  @Test("JSONWorkoutSource reads a gzipped archive from data")
  func gzippedArchiveData() async throws {
    let fixtures = try WorkoutFixturePreset.allFixtures()
    let archive = try WorkoutFixtureArchive(fixtures: fixtures)
    let compressed = try GzipCodec.compress(FixtureArchiveJSONCodec().encode(archive))
    let source = try JSONWorkoutSource(data: compressed)
    #expect(source.fixtures.count == fixtures.count)
  }

  @Test("JSONWorkoutSource reads a gzipped fixture file from disk")
  func gzippedFixtureFile() async throws {
    let fixture = try WorkoutFixturePreset.outdoorRun.fixture()
    let compressed = try GzipCodec.compress(FixtureJSONCodec().encode(fixture))
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).json.gz")
    try compressed.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try JSONWorkoutSource(url: url)
    #expect(source.fixtures.map(\.id) == [fixture.id])
  }
}
