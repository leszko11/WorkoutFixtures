#if canImport(HealthKit)
  import CoreLocation
  import Foundation
  import HealthKit
  import WorkoutFixtures

  /// Translates a `WorkoutQuery` into the predicate, sort, and limit that
  /// `HKSampleQueryDescriptor` understands, so filtering happens inside
  /// HealthKit instead of in memory.
  struct HealthKitQueryPlan {
    let predicate: NSPredicate?
    let sortDescriptors: [SortDescriptor<HKWorkout>]
    let limit: Int?

    init(query: WorkoutQuery) {
      var subpredicates: [NSPredicate] = []
      if query.startDate != nil || query.endDate != nil {
        subpredicates.append(
          HKQuery.predicateForSamples(
            withStart: query.startDate,
            end: query.endDate,
            options: []
          )
        )
      }
      if !query.activities.isEmpty {
        let activityPredicates = query.activities
          .sorted { $0.rawValue < $1.rawValue }
          .map { HKQuery.predicateForWorkouts(with: $0.healthKitType) }
        subpredicates.append(
          NSCompoundPredicate(orPredicateWithSubpredicates: activityPredicates)
        )
      }
      switch subpredicates.count {
      case 0: predicate = nil
      case 1: predicate = subpredicates[0]
      default: predicate = NSCompoundPredicate(andPredicateWithSubpredicates: subpredicates)
      }
      sortDescriptors = [
        SortDescriptor(
          \.startDate,
          order: query.sort == .startDateAscending ? .forward : .reverse
        )
      ]
      limit = query.limit.map { max(0, $0) }
    }
  }

  /// Reads workouts out of HealthKit as fixtures.
  ///
  /// Query filters, sorting, and limits are pushed down into HealthKit predicates rather than
  /// applied in memory, so only matching workouts are fetched. Only running, walking, and
  /// cycling workouts are surfaced; other activity types are skipped. Loaded fixtures are
  /// normalized — samples, events, and route points sorted and clamped into the workout's
  /// bounds, unbalanced pause/resume events dropped — so they pass `WorkoutValidator` even
  /// when HealthKit's raw data would not.
  public struct HealthKitWorkoutSource: WorkoutFixtureSource, Sendable {
    private let healthStore: HKHealthStore
    private let timeZone: TimeZone

    /// Creates a source over `healthStore`.
    /// - Parameter timeZone: Fallback used when a workout carries no (or an invalid)
    ///   `HKMetadataKeyTimeZone`.
    public init(healthStore: HKHealthStore, timeZone: TimeZone = .current) {
      self.healthStore = healthStore
      self.timeZone = timeZone
    }

    /// Prefers the workout's own `HKMetadataKeyTimeZone` and falls back to the
    /// injected zone when the metadata is absent or names an unknown zone.
    static func resolvedTimeZoneIdentifier(
      metadata: [String: Any]?,
      fallback: TimeZone
    ) -> String {
      guard let identifier = metadata?[HKMetadataKeyTimeZone] as? String,
        TimeZone(identifier: identifier) != nil
      else {
        return fallback.identifier
      }
      return identifier
    }

    /// Fetches matching workouts with one HealthKit query, then builds their summaries
    /// concurrently while preserving the query's sort order.
    public func summaries(matching query: WorkoutQuery) async throws -> [WorkoutSummary] {
      let plan = HealthKitQueryPlan(query: query)
      if plan.limit == 0 { return [] }
      let descriptor = HKSampleQueryDescriptor<HKWorkout>(
        predicates: [.workout(plan.predicate)],
        sortDescriptors: plan.sortDescriptors,
        limit: plan.limit
      )
      let workouts = try await descriptor.result(for: healthStore)
      // The plan already filters by activity in HealthKit; drop only workouts
      // whose HKWorkoutActivityType has no fixture mapping.
      let matches = workouts.compactMap { workout in
        workout.workoutActivityType.fixtureActivity.map { (workout: workout, activity: $0) }
      }
      try Task.checkCancellation()
      return try await withThrowingTaskGroup(of: (Int, WorkoutSummary).self) { group in
        for (index, match) in matches.enumerated() {
          group.addTask {
            try Task.checkCancellation()
            return (index, try await makeSummary(match.workout, activity: match.activity))
          }
        }
        var summaries = [WorkoutSummary?](repeating: nil, count: matches.count)
        for try await (index, summary) in group {
          summaries[index] = summary
        }
        return summaries.compactMap { $0 }
      }
    }

    /// Loads the complete workout — metric series, events, and route fetched concurrently —
    /// for the HealthKit workout whose UUID is `id`, normalized into a valid fixture with
    /// `.captured` provenance.
    /// - Throws: `WorkoutFixtureSourceError.notFound` when `id` is not a UUID, no workout
    ///   matches, or the workout's activity type has no fixture mapping.
    public func fixture(for id: WorkoutID) async throws -> WorkoutFixture {
      guard let uuid = UUID(uuidString: id.rawValue) else {
        throw WorkoutFixtureSourceError.notFound(id)
      }
      let predicate = HKQuery.predicateForObject(with: uuid)
      let descriptor = HKSampleQueryDescriptor<HKWorkout>(
        predicates: [.workout(predicate)],
        sortDescriptors: [],
        limit: 1
      )
      guard let workout = try await descriptor.result(for: healthStore).first,
        let activity = workout.workoutActivityType.fixtureActivity
      else {
        throw WorkoutFixtureSourceError.notFound(id)
      }

      async let heartRate = quantitySeries(.heartRate, activity: activity, workout: workout)
      async let distance = quantitySeries(.distance, activity: activity, workout: workout)
      async let activeEnergy = quantitySeries(.activeEnergy, activity: activity, workout: workout)
      async let route = workoutRoute(for: workout)

      let series = try await [heartRate, distance, activeEnergy].compactMap { $0 }
      let fixture = WorkoutFixture(
        id: id,
        workout: WorkoutDescriptor(
          activity: activity,
          location: workout.fixtureLocation,
          startDate: workout.startDate,
          endDate: workout.endDate,
          timeZoneIdentifier: Self.resolvedTimeZoneIdentifier(
            metadata: workout.metadata,
            fallback: timeZone
          )
        ),
        series: series,
        events: workout.workoutEvents?.compactMap(WorkoutEvent.init(healthKitEvent:)) ?? [],
        route: try await route,
        provenance: FixtureProvenance(
          kind: .captured,
          createdAt: workout.startDate,
          source: SourceProvenance(
            name: workout.sourceRevision.source.name,
            bundleIdentifier: workout.sourceRevision.source.bundleIdentifier,
            version: workout.sourceRevision.version,
            deviceModel: workout.device?.model
          )
        )
      )
      return HealthKitFixtureNormalizer.normalize(fixture)
    }

    private func makeSummary(
      _ workout: HKWorkout,
      activity: WorkoutActivity
    ) async throws -> WorkoutSummary {
      let distanceType = HealthKitTypes.distanceType(for: activity)
      let distance = workout.statistics(for: distanceType)?.sumQuantity()?
        .doubleValue(for: .meter())
      let energy = workout.statistics(for: HealthKitTypes.activeEnergy)?.sumQuantity()?
        .doubleValue(for: .kilocalorie())
      let heartRate = workout.statistics(for: HealthKitTypes.heartRate)?.averageQuantity()?
        .doubleValue(for: HKUnit(from: UnitIdentifier.countPerMinute.rawValue))
      let routePredicate = HKQuery.predicateForObjects(from: workout)
      let routeDescriptor = HKSampleQueryDescriptor<HKWorkoutRoute>(
        predicates: [.workoutRoute(routePredicate)],
        sortDescriptors: [],
        limit: 1
      )
      let hasRoute = try await !routeDescriptor.result(for: healthStore).isEmpty
      return WorkoutSummary(
        id: WorkoutID(rawValue: workout.uuid.uuidString),
        activity: activity,
        location: workout.fixtureLocation,
        startDate: workout.startDate,
        endDate: workout.endDate,
        elapsedDuration: workout.endDate.timeIntervalSince(workout.startDate),
        activeDuration: workout.duration,
        distanceMeters: distance,
        activeEnergyKilocalories: energy,
        averageHeartRate: heartRate,
        hasRoute: hasRoute
      )
    }

    private func quantitySeries(
      _ metric: MetricIdentifier,
      activity: WorkoutActivity,
      workout: HKWorkout
    ) async throws -> MetricSeries? {
      let type = HealthKitTypes.quantityType(for: metric, activity: activity)
      let predicate = HKQuery.predicateForObjects(from: workout)
      let descriptor = HKSampleQueryDescriptor<HKQuantitySample>(
        predicates: [.quantitySample(type: type, predicate: predicate)],
        sortDescriptors: [SortDescriptor(\HKQuantitySample.startDate)]
      )
      let samples = try await descriptor.result(for: healthStore)
      guard !samples.isEmpty else { return nil }
      let unit = HealthKitTypes.unit(for: metric)
      return MetricSeries(
        metric: metric,
        samples: samples.map {
          MetricSample(
            startDate: $0.startDate,
            endDate: $0.endDate,
            value: $0.quantity.doubleValue(for: unit)
          )
        }
      )
    }

    private func workoutRoute(for workout: HKWorkout) async throws -> WorkoutRoute? {
      let predicate = HKQuery.predicateForObjects(from: workout)
      let descriptor = HKSampleQueryDescriptor<HKWorkoutRoute>(
        predicates: [.workoutRoute(predicate)],
        sortDescriptors: [SortDescriptor(\HKWorkoutRoute.startDate)]
      )
      let routes = try await descriptor.result(for: healthStore)
      guard !routes.isEmpty else { return nil }
      var points: [RoutePoint] = []
      for route in routes {
        for try await location in HKWorkoutRouteQueryDescriptor(route).results(for: healthStore) {
          try Task.checkCancellation()
          points.append(RoutePoint(location: location))
        }
      }
      return WorkoutRoute(points: points.sorted { $0.date < $1.date })
    }
  }

  extension WorkoutEvent {
    fileprivate init?(healthKitEvent event: HKWorkoutEvent) {
      let kind: WorkoutEventKind
      switch event.type {
      case .pause, .motionPaused: kind = .pause
      case .resume, .motionResumed: kind = .resume
      case .lap: kind = .lap
      case .segment: kind = .segment
      case .marker: kind = .marker
      default: return nil
      }
      self.init(
        kind: kind,
        startDate: event.dateInterval.start,
        endDate: event.dateInterval.end
      )
    }
  }

  extension RoutePoint {
    fileprivate init(location: CLLocation) {
      self.init(
        date: location.timestamp,
        latitude: location.coordinate.latitude,
        longitude: location.coordinate.longitude,
        altitude: location.altitude,
        horizontalAccuracy: location.horizontalAccuracy,
        verticalAccuracy: location.verticalAccuracy,
        speed: location.speed,
        course: location.course
      )
    }
  }

  enum HealthKitFixtureNormalizer {
    static func normalize(_ fixture: WorkoutFixture) -> WorkoutFixture {
      WorkoutFixture(
        schemaVersion: fixture.schemaVersion,
        id: fixture.id,
        workout: fixture.workout,
        series: fixture.series.map { normalize($0, within: fixture.workout) },
        events: normalize(fixture.events, within: fixture.workout),
        route: fixture.route.map { normalize($0, within: fixture.workout) },
        provenance: fixture.provenance
      )
    }

    private static func normalize(
      _ series: MetricSeries,
      within workout: WorkoutDescriptor
    ) -> MetricSeries {
      var previousEnd: Date?
      let samples = series.samples
        .enumerated()
        .sorted {
          ($0.element.startDate, $0.element.endDate, $0.offset)
            < ($1.element.startDate, $1.element.endDate, $1.offset)
        }
        .map { _, sample in
          let clampedStart = clamp(sample.startDate, within: workout)
          let clampedEnd = clamp(sample.endDate, within: workout)
          let startDate = max(clampedStart, previousEnd ?? clampedStart)
          let endDate = max(startDate, clampedEnd)
          previousEnd = endDate
          return MetricSample(startDate: startDate, endDate: endDate, value: sample.value)
        }
      return MetricSeries(metric: series.metric, unit: series.unit, samples: samples)
    }

    private static func normalize(
      _ events: [WorkoutEvent],
      within workout: WorkoutDescriptor
    ) -> [WorkoutEvent] {
      var isPaused = false
      var normalized: [WorkoutEvent] = []
      for (_, event) in events.enumerated().sorted(by: {
        ($0.element.startDate, $0.element.endDate, $0.offset)
          < ($1.element.startDate, $1.element.endDate, $1.offset)
      }) {
        switch event.kind {
        case .pause where isPaused, .resume where !isPaused:
          continue
        case .pause:
          isPaused = true
        case .resume:
          isPaused = false
        case .lap, .segment, .marker:
          break
        }
        let startDate = clamp(event.startDate, within: workout)
        let endDate = max(startDate, clamp(event.endDate, within: workout))
        normalized.append(
          WorkoutEvent(kind: event.kind, startDate: startDate, endDate: endDate)
        )
      }
      return normalized
    }

    private static func normalize(
      _ route: WorkoutRoute,
      within workout: WorkoutDescriptor
    ) -> WorkoutRoute {
      WorkoutRoute(
        points: route.points
          .enumerated()
          .sorted {
            ($0.element.date, $0.offset) < ($1.element.date, $1.offset)
          }
          .map { _, point in
            RoutePoint(
              date: clamp(point.date, within: workout),
              latitude: point.latitude,
              longitude: point.longitude,
              altitude: point.altitude,
              horizontalAccuracy: point.horizontalAccuracy,
              verticalAccuracy: point.verticalAccuracy,
              speed: point.speed,
              course: point.course
            )
          }
      )
    }

    private static func clamp(_ date: Date, within workout: WorkoutDescriptor) -> Date {
      min(max(date, workout.startDate), workout.endDate)
    }
  }
#endif
