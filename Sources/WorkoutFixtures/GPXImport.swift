import Foundation

#if canImport(FoundationXML)
  import FoundationXML
#endif

/// Options that control how a GPX document is converted into a ``WorkoutFixture``.
public struct GPXImportOptions: Sendable {
  /// The activity recorded by the imported workout. Defaults to ``WorkoutActivity/running``.
  public var activity: WorkoutActivity = .running

  /// The location kind of the imported workout. Defaults to ``WorkoutLocation/outdoor``.
  public var location: WorkoutLocation = .outdoor

  /// An explicit fixture identifier. When `nil`, an identifier is derived from the GPX track
  /// name (`gpx-<sanitized name>`) or from the point count when the track is unnamed.
  public var id: WorkoutID?

  /// The IANA time-zone identifier stored on the fixture. GPX timestamps are UTC, so the
  /// default is `"UTC"`.
  public var timeZoneIdentifier: String = "UTC"

  /// Whether a cumulative distance series is derived from consecutive route points using the
  /// haversine formula. Defaults to `true`.
  public var deriveDistanceSeries: Bool = true

  /// Creates options with the default running/outdoor/UTC configuration.
  public init() {}
}

/// Errors thrown while importing a GPX document.
public enum GPXImportError: Error, Equatable, Sendable, LocalizedError {
  /// The document is not well-formed XML. Carries the parser's line and column position.
  case malformedXML(line: Int, column: Int)
  /// The document contains no usable track points, or too few to form a valid workout.
  case noTrackPoints
  /// The track point at the given index has no parseable `<time>` element.
  case missingTimestamp(pointIndex: Int)
  /// The track point at the given index is earlier than the preceding track point.
  case nonMonotonicTimestamp(pointIndex: Int)
  /// The track point at the given index has a missing or out-of-range `lat`/`lon` attribute.
  case invalidCoordinate(pointIndex: Int)

  public var errorDescription: String? {
    switch self {
    case .malformedXML(let line, let column):
      "The GPX document is not well-formed XML (line \(line), column \(column))."
    case .noTrackPoints:
      "The GPX document does not contain enough usable track points."
    case .missingTimestamp(let pointIndex):
      "Track point \(pointIndex) is missing a parseable <time> element."
    case .nonMonotonicTimestamp(let pointIndex):
      "Track point \(pointIndex) is earlier than the preceding track point."
    case .invalidCoordinate(let pointIndex):
      "Track point \(pointIndex) has a missing or out-of-range lat/lon attribute."
    }
  }
}

/// Imports GPX 1.1 tracks as validated ``WorkoutFixture`` values.
///
/// The importer reads every `trkpt` across all `trkseg` elements, requires an ISO-8601
/// `<time>` on each point, and recognizes heart-rate extension values from any descendant
/// element whose local name is `hr` regardless of its namespace prefix (`gpxtpx:hr`,
/// `ns3:hr`, and similar). Parsing is fully synchronous and self-contained.
public struct GPXWorkoutImporter: Sendable {
  /// Creates an importer.
  public init() {}

  /// Imports a GPX document from in-memory data.
  ///
  /// - Parameters:
  ///   - data: The GPX document bytes.
  ///   - options: Import options; see ``GPXImportOptions``.
  /// - Returns: A fixture that has passed ``WorkoutValidator/requireValid(_:)``.
  /// - Throws: ``GPXImportError`` for malformed input, or ``FixtureValidationError`` when
  ///   the assembled fixture fails validation.
  public func fixture(
    from data: Data,
    options: GPXImportOptions = GPXImportOptions()
  ) throws -> WorkoutFixture {
    let delegate = GPXParsingDelegate()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse() else {
      throw GPXImportError.malformedXML(line: parser.lineNumber, column: parser.columnNumber)
    }
    return try makeFixture(
      rawPoints: delegate.points,
      trackName: delegate.trackName,
      options: options
    )
  }

  /// Imports a GPX document from a file URL.
  ///
  /// - Parameters:
  ///   - url: The location of the GPX file.
  ///   - options: Import options; see ``GPXImportOptions``.
  /// - Returns: A fixture that has passed ``WorkoutValidator/requireValid(_:)``.
  public func fixture(
    contentsOf url: URL,
    options: GPXImportOptions = GPXImportOptions()
  ) throws -> WorkoutFixture {
    try fixture(from: Data(contentsOf: url), options: options)
  }

  private func makeFixture(
    rawPoints: [RawGPXTrackPoint],
    trackName: String?,
    options: GPXImportOptions
  ) throws -> WorkoutFixture {
    guard !rawPoints.isEmpty else { throw GPXImportError.noTrackPoints }

    let plainFormatter = ISO8601DateFormatter()
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    var points: [ResolvedGPXTrackPoint] = []
    points.reserveCapacity(rawPoints.count)
    for (index, raw) in rawPoints.enumerated() {
      guard
        let latitude = raw.latitudeText.flatMap(Double.init),
        let longitude = raw.longitudeText.flatMap(Double.init),
        latitude.isFinite, longitude.isFinite,
        (-90.0...90.0).contains(latitude), (-180.0...180.0).contains(longitude)
      else {
        throw GPXImportError.invalidCoordinate(pointIndex: index)
      }
      guard
        let timeText = raw.timeText,
        let date = plainFormatter.date(from: timeText) ?? fractionalFormatter.date(from: timeText)
      else {
        throw GPXImportError.missingTimestamp(pointIndex: index)
      }
      if let previousDate = points.last?.date, date < previousDate {
        throw GPXImportError.nonMonotonicTimestamp(pointIndex: index)
      }
      points.append(
        ResolvedGPXTrackPoint(
          date: date,
          latitude: latitude,
          longitude: longitude,
          altitude: raw.elevationText.flatMap(Double.init),
          heartRate: raw.heartRateText.flatMap(Double.init)
        ))
    }

    guard let first = points.first, let last = points.last, points.count >= 2,
      first.date < last.date
    else {
      throw GPXImportError.noTrackPoints
    }

    let workout = WorkoutDescriptor(
      activity: options.activity,
      location: options.location,
      startDate: first.date,
      endDate: last.date,
      timeZoneIdentifier: options.timeZoneIdentifier
    )
    let route = WorkoutRoute(
      points: points.map {
        RoutePoint(
          date: $0.date, latitude: $0.latitude, longitude: $0.longitude, altitude: $0.altitude)
      })

    var series: [MetricSeries] = []
    if options.deriveDistanceSeries {
      var samples: [MetricSample] = []
      samples.reserveCapacity(points.count - 1)
      for index in 1..<points.count {
        let previous = points[index - 1]
        let current = points[index]
        let meters = haversineMeters(
          latitude1: previous.latitude, longitude1: previous.longitude,
          latitude2: current.latitude, longitude2: current.longitude
        )
        samples.append(MetricSample(startDate: previous.date, endDate: current.date, value: meters))
      }
      series.append(
        MetricSeries(
          metric: .distance, unit: MetricIdentifier.distance.canonicalUnit, samples: samples))
    }
    let heartRateSamples: [MetricSample] = points.indices.compactMap { index in
      guard let heartRate = points[index].heartRate else { return nil }
      let endDate = index + 1 < points.count ? points[index + 1].date : points[index].date
      return MetricSample(startDate: points[index].date, endDate: endDate, value: heartRate)
    }
    if !heartRateSamples.isEmpty {
      series.append(
        MetricSeries(
          metric: .heartRate,
          unit: MetricIdentifier.heartRate.canonicalUnit,
          samples: heartRateSamples
        ))
    }

    let fixture = WorkoutFixture(
      id: options.id ?? defaultIdentifier(trackName: trackName, pointCount: points.count),
      workout: workout,
      series: series,
      route: route,
      provenance: FixtureProvenance(
        kind: .authored,
        createdAt: first.date,
        generatorVersion: TemplateWorkoutGenerator.generatorVersion,
        source: SourceProvenance(name: "gpx-import")
      )
    )
    try WorkoutValidator().requireValid(fixture)
    return fixture
  }

  private func defaultIdentifier(trackName: String?, pointCount: Int) -> WorkoutID {
    if let trackName, let sanitized = sanitizedIdentifierComponent(trackName) {
      return WorkoutID(rawValue: "gpx-\(sanitized)")
    }
    return WorkoutID(rawValue: "gpx-\(pointCount)-points")
  }

  private func sanitizedIdentifierComponent(_ name: String) -> String? {
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
    var result = ""
    var lastWasSeparator = true
    for character in name.lowercased() {
      if allowed.contains(character) {
        result.append(character)
        lastWasSeparator = false
      } else if !lastWasSeparator {
        result.append("-")
        lastWasSeparator = true
      }
    }
    while result.hasSuffix("-") {
      result.removeLast()
    }
    return result.isEmpty ? nil : result
  }

  private func haversineMeters(
    latitude1: Double,
    longitude1: Double,
    latitude2: Double,
    longitude2: Double
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

/// A track point as read from the document, before coordinate and timestamp validation.
private struct RawGPXTrackPoint {
  var latitudeText: String?
  var longitudeText: String?
  var elevationText: String?
  var timeText: String?
  var heartRateText: String?
}

/// A track point after coordinate and timestamp validation.
private struct ResolvedGPXTrackPoint {
  let date: Date
  let latitude: Double
  let longitude: Double
  let altitude: Double?
  let heartRate: Double?
}

/// Collects GPX track data during a single synchronous `XMLParser` run. The delegate is
/// confined to the importer's parse call and never crosses a concurrency boundary.
private final class GPXParsingDelegate: NSObject, XMLParserDelegate {
  private(set) var trackName: String?
  private(set) var points: [RawGPXTrackPoint] = []

  private var elementStack: [String] = []
  private var textBuffer = ""
  private var isInsideTrackPoint = false

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName: String?,
    attributes attributeDict: [String: String]
  ) {
    let localName = Self.localName(of: elementName)
    elementStack.append(localName)
    textBuffer = ""
    if localName == "trkpt" {
      isInsideTrackPoint = true
      points.append(
        RawGPXTrackPoint(
          latitudeText: attributeDict["lat"],
          longitudeText: attributeDict["lon"]
        ))
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    textBuffer += string
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName: String?
  ) {
    let localName = Self.localName(of: elementName)
    let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
    let parentName = elementStack.count >= 2 ? elementStack[elementStack.count - 2] : nil
    if !elementStack.isEmpty {
      elementStack.removeLast()
    }
    textBuffer = ""

    if localName == "trkpt" {
      isInsideTrackPoint = false
      return
    }
    if localName == "name", parentName == "trk", trackName == nil {
      trackName = text
      return
    }
    guard isInsideTrackPoint, !points.isEmpty else { return }
    switch localName {
    case "ele":
      points[points.count - 1].elevationText = text
    case "time":
      points[points.count - 1].timeText = text
    case "hr":
      points[points.count - 1].heartRateText = text
    default:
      break
    }
  }

  private static func localName(of elementName: String) -> String {
    guard let separatorIndex = elementName.lastIndex(of: ":") else { return elementName }
    return String(elementName[elementName.index(after: separatorIndex)...])
  }
}
