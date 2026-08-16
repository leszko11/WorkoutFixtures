#if canImport(HealthKit)
  import CoreLocation
  import Foundation
  import HealthKit
  import WorkoutFixtures

  public struct HealthKitWorkoutSource: WorkoutFixtureSource, Sendable {
    private let healthStore: HKHealthStore
    private let timeZone: TimeZone

    public init(healthStore: HKHealthStore, timeZone: TimeZone = .current) {
      self.healthStore = healthStore
      self.timeZone = timeZone
    }

    public func summaries(matching query: WorkoutQuery) async throws -> [WorkoutSummary] {
      let descriptor = HKSampleQueryDescriptor<HKWorkout>(
        predicates: [.workout()],
        sortDescriptors: [SortDescriptor(\HKWorkout.startDate, order: .reverse)]
      )
      let workouts = try await descriptor.result(for: healthStore)
      var summaries: [WorkoutSummary] = []
      for workout in workouts {
        try Task.checkCancellation()
        guard let activity = workout.workoutActivityType.fixtureActivity,
          query.activities.isEmpty || query.activities.contains(activity),
          query.startDate.map({ $0 <= workout.endDate }) ?? true,
          query.endDate.map({ $0 >= workout.startDate }) ?? true
        else { continue }
        summaries.append(try await makeSummary(workout, activity: activity))
      }
      summaries.sort {
        query.sort == .startDateAscending
          ? $0.startDate < $1.startDate
          : $0.startDate > $1.startDate
      }
      return query.limit.map { Array(summaries.prefix(max(0, $0))) } ?? summaries
    }

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
          timeZoneIdentifier: timeZone.identifier
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
