import Foundation
import Testing
import WorkoutFixtures

@Suite("GPX import")
struct GPXImportTests {
  private let importer = GPXWorkoutImporter()

  private let happyPathGPX = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1"
      xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
      <trk>
        <name>Morning Run</name>
        <trkseg>
          <trkpt lat="50.0600" lon="19.9360">
            <ele>210.0</ele>
            <time>2024-05-01T06:00:00Z</time>
            <extensions>
              <gpxtpx:TrackPointExtension>
                <gpxtpx:hr>120</gpxtpx:hr>
              </gpxtpx:TrackPointExtension>
            </extensions>
          </trkpt>
          <trkpt lat="50.0610" lon="19.9375">
            <ele>211.5</ele>
            <time>2024-05-01T06:01:00Z</time>
            <extensions>
              <gpxtpx:TrackPointExtension>
                <gpxtpx:hr>132</gpxtpx:hr>
              </gpxtpx:TrackPointExtension>
            </extensions>
          </trkpt>
        </trkseg>
        <trkseg>
          <trkpt lat="50.0621" lon="19.9391">
            <ele>213.0</ele>
            <time>2024-05-01T06:02:00Z</time>
            <extensions>
              <gpxtpx:TrackPointExtension>
                <gpxtpx:hr>141</gpxtpx:hr>
              </gpxtpx:TrackPointExtension>
            </extensions>
          </trkpt>
        </trkseg>
      </trk>
    </gpx>
    """

  @Test("Happy path builds a validated fixture with route, distance, and heart rate")
  func happyPath() throws {
    let fixture = try importer.fixture(from: Data(happyPathGPX.utf8))

    #expect(WorkoutValidator().validate(fixture).contains { $0.severity == .error } == false)
    #expect(fixture.id.rawValue == "gpx-morning-run")
    #expect(fixture.workout.activity == .running)
    #expect(fixture.workout.location == .outdoor)
    #expect(fixture.workout.timeZoneIdentifier == "UTC")
    #expect(try fixture.workout.startDate == isoDate("2024-05-01T06:00:00Z"))
    #expect(try fixture.workout.endDate == isoDate("2024-05-01T06:02:00Z"))

    let route = try #require(fixture.route)
    #expect(route.points.count == 3)
    #expect(route.points[0].altitude == 210.0)
    #expect(try route.points[2].date == isoDate("2024-05-01T06:02:00Z"))

    let expectedDistance =
      haversineMeters(50.0600, 19.9360, 50.0610, 19.9375)
      + haversineMeters(50.0610, 19.9375, 50.0621, 19.9391)
    let total = try #require(fixture.total(for: .distance))
    #expect(abs(total - expectedDistance) < 0.5)

    let heartRate = try #require(fixture.series(for: .heartRate))
    #expect(heartRate.samples.count == 3)
    #expect(heartRate.samples[0].value == 120)
    #expect(try heartRate.samples[0].startDate == isoDate("2024-05-01T06:00:00Z"))
    #expect(try heartRate.samples[0].endDate == isoDate("2024-05-01T06:01:00Z"))
    #expect(heartRate.samples[2].value == 141)
    #expect(heartRate.samples[2].startDate == heartRate.samples[2].endDate)
  }

  @Test("Heart rate is recognized under any namespace prefix")
  func namespacePrefixVariance() throws {
    let gpx = gpxDocument(
      body: """
        <trkpt lat="50.0600" lon="19.9360">
          <time>2024-05-01T06:00:00Z</time>
          <extensions><ns3:TrackPointExtension><ns3:hr>118</ns3:hr></ns3:TrackPointExtension></extensions>
        </trkpt>
        <trkpt lat="50.0610" lon="19.9375">
          <time>2024-05-01T06:01:00Z</time>
          <extensions><ns3:TrackPointExtension><ns3:hr>127</ns3:hr></ns3:TrackPointExtension></extensions>
        </trkpt>
        """)
    let fixture = try importer.fixture(from: Data(gpx.utf8))
    let heartRate = try #require(fixture.series(for: .heartRate))
    #expect(heartRate.samples.map(\.value) == [118, 127])
  }

  @Test("A point without a time element is rejected with its index")
  func missingTimestamp() {
    let gpx = gpxDocument(
      body: """
        <trkpt lat="50.0600" lon="19.9360"><time>2024-05-01T06:00:00Z</time></trkpt>
        <trkpt lat="50.0610" lon="19.9375"></trkpt>
        """)
    #expect(throws: GPXImportError.missingTimestamp(pointIndex: 1)) {
      try importer.fixture(from: Data(gpx.utf8))
    }
  }

  @Test("Out-of-order timestamps are rejected with the offending index")
  func nonMonotonicTimestamps() {
    let gpx = gpxDocument(
      body: """
        <trkpt lat="50.0600" lon="19.9360"><time>2024-05-01T06:00:00Z</time></trkpt>
        <trkpt lat="50.0610" lon="19.9375"><time>2024-05-01T06:01:00Z</time></trkpt>
        <trkpt lat="50.0621" lon="19.9391"><time>2024-05-01T06:00:30Z</time></trkpt>
        """)
    #expect(throws: GPXImportError.nonMonotonicTimestamp(pointIndex: 2)) {
      try importer.fixture(from: Data(gpx.utf8))
    }
  }

  @Test("A track without points is rejected")
  func emptyTrack() {
    let gpx = gpxDocument(body: "")
    #expect(throws: GPXImportError.noTrackPoints) {
      try importer.fixture(from: Data(gpx.utf8))
    }
  }

  @Test("A single point cannot form a workout")
  func singlePointIsRejected() {
    let gpx = gpxDocument(
      body: """
        <trkpt lat="50.0600" lon="19.9360"><time>2024-05-01T06:00:00Z</time></trkpt>
        """)
    #expect(throws: GPXImportError.noTrackPoints) {
      try importer.fixture(from: Data(gpx.utf8))
    }
  }

  @Test("An out-of-range latitude is rejected with its index")
  func invalidLatitude() {
    let gpx = gpxDocument(
      body: """
        <trkpt lat="95.0" lon="19.9360"><time>2024-05-01T06:00:00Z</time></trkpt>
        <trkpt lat="50.0610" lon="19.9375"><time>2024-05-01T06:01:00Z</time></trkpt>
        """)
    #expect(throws: GPXImportError.invalidCoordinate(pointIndex: 0)) {
      try importer.fixture(from: Data(gpx.utf8))
    }
  }

  @Test("Malformed XML is rejected")
  func malformedXML() {
    #expect(throws: GPXImportError.self) {
      try importer.fixture(from: Data("<gpx><trk>".utf8))
    }
  }

  @Test("Distance derivation can be disabled")
  func distanceSeriesDisabled() throws {
    var options = GPXImportOptions()
    options.deriveDistanceSeries = false
    let fixture = try importer.fixture(from: Data(happyPathGPX.utf8), options: options)
    #expect(fixture.series(for: .distance) == nil)
    #expect(fixture.series(for: .heartRate) != nil)
    #expect(WorkoutValidator().validate(fixture).contains { $0.severity == .error } == false)
  }

  @Test("A custom identifier from options is used verbatim")
  func customIdentifier() throws {
    var options = GPXImportOptions()
    options.id = "my-custom-id"
    let fixture = try importer.fixture(from: Data(happyPathGPX.utf8), options: options)
    #expect(fixture.id == "my-custom-id")
  }

  @Test("An unnamed track falls back to a point-count identifier")
  func unnamedTrackIdentifierFallback() throws {
    let gpx = gpxDocument(
      name: nil,
      body: """
        <trkpt lat="50.0600" lon="19.9360"><time>2024-05-01T06:00:00Z</time></trkpt>
        <trkpt lat="50.0610" lon="19.9375"><time>2024-05-01T06:01:00Z</time></trkpt>
        """)
    let fixture = try importer.fixture(from: Data(gpx.utf8))
    #expect(fixture.id.rawValue == "gpx-2-points")
  }

  private func gpxDocument(name: String? = "Test Track", body: String) -> String {
    let nameElement = name.map { "<name>\($0)</name>" } ?? ""
    return """
      <?xml version="1.0" encoding="UTF-8"?>
      <gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
        <trk>
          \(nameElement)
          <trkseg>
      \(body)
          </trkseg>
        </trk>
      </gpx>
      """
  }

  private func isoDate(_ value: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: value))
  }

  private func haversineMeters(
    _ latitude1: Double, _ longitude1: Double, _ latitude2: Double, _ longitude2: Double
  ) -> Double {
    let earthRadius = 6_371_000.0
    let phi1 = latitude1 * .pi / 180
    let phi2 = latitude2 * .pi / 180
    let deltaPhi = (latitude2 - latitude1) * .pi / 180
    let deltaLambda = (longitude2 - longitude1) * .pi / 180
    let a =
      sin(deltaPhi / 2) * sin(deltaPhi / 2)
      + cos(phi1) * cos(phi2) * sin(deltaLambda / 2) * sin(deltaLambda / 2)
    return 2 * earthRadius * asin(min(1, sqrt(a)))
  }
}
