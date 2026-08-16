#if canImport(HealthKit)
  import CoreLocation
  import Foundation
  import HealthKit
  import WorkoutFixtures

  public enum HealthKitImportError: Error, Equatable, Sendable, LocalizedError {
    case routeBuilderUnavailable
    case finishReturnedNoWorkout
    case finishReturnedNoRoute
    case cleanupFailed(primary: String, cleanup: String)

    public var errorDescription: String? {
      switch self {
      case .routeBuilderUnavailable:
        "HealthKit did not provide a workout route builder."
      case .finishReturnedNoWorkout:
        "HealthKit finished saving but the workout is temporarily unavailable."
      case .finishReturnedNoRoute:
        "HealthKit finished saving but the workout route is temporarily unavailable."
      case .cleanupFailed(let primary, let cleanup):
        "Import failed (\(primary)); rollback also failed (\(cleanup))."
      }
    }
  }

  public actor HealthKitWorkoutSink: WorkoutFixtureSink {
    private let healthStore: HKHealthStore
    private let validator: WorkoutValidator
    private var activeImports: Set<WorkoutID> = []

    public init(
      healthStore: HKHealthStore,
      validator: WorkoutValidator = WorkoutValidator()
    ) {
      self.healthStore = healthStore
      self.validator = validator
    }

    public func store(_ fixture: WorkoutFixture) async throws -> StoredWorkout {
      try validator.requireValid(fixture)
      try Task.checkCancellation()

      let configuration = HKWorkoutConfiguration()
      configuration.activityType = fixture.workout.activity.healthKitType
      configuration.locationType = fixture.workout.location.healthKitType
      let builder = HKWorkoutBuilder(
        healthStore: healthStore,
        configuration: configuration,
        device: nil
      )
      let samples = makeSamples(from: fixture)
      activeImports.insert(fixture.id)
      defer { activeImports.remove(fixture.id) }
      var routeBuilder: HKWorkoutRouteBuilder?
      var savedWorkout: HKWorkout?

      return try await withTaskCancellationHandler {
        do {
          try await builder.beginCollection(at: fixture.workout.startDate)
          for chunk in samples.chunked(into: 500) {
            try Task.checkCancellation()
            try await builder.addSamples(chunk)
          }
          let events = fixture.events.map(\.healthKitEvent)
          if !events.isEmpty {
            try await builder.addWorkoutEvents(events)
          }
          if let route = fixture.route, !route.points.isEmpty {
            guard
              let builder = builder.seriesBuilder(for: HealthKitTypes.route)
                as? HKWorkoutRouteBuilder
            else {
              throw HealthKitImportError.routeBuilderUnavailable
            }
            routeBuilder = builder
            for chunk in route.points.map(\.location).chunked(into: 100) {
              try Task.checkCancellation()
              try await builder.insertRouteData(chunk)
            }
          }
          try Task.checkCancellation()
          try await builder.endCollection(at: fixture.workout.endDate)
          let workout = try await finish(builder)
          savedWorkout = workout
          try Task.checkCancellation()
          if let routeBuilder {
            guard let workout else {
              throw HealthKitImportError.finishReturnedNoWorkout
            }
            guard try await finish(routeBuilder, with: workout) != nil else {
              throw HealthKitImportError.finishReturnedNoRoute
            }
            try Task.checkCancellation()
          }
          return StoredWorkout(
            fixtureID: fixture.id,
            externalID: workout?.uuid.uuidString,
            storedAt: fixture.workout.endDate,
            status: workout == nil ? .savedUnavailable : .available
          )
        } catch {
          builder.discardWorkout()
          routeBuilder?.discard()
          do {
            if let savedWorkout {
              try await healthStore.delete(savedWorkout)
            }
            if savedWorkout != nil, !samples.isEmpty {
              try await healthStore.delete(samples)
            }
          } catch let cleanupError {
            throw HealthKitImportError.cleanupFailed(
              primary: String(describing: error),
              cleanup: String(describing: cleanupError)
            )
          }
          throw error
        }
      } onCancel: {
        builder.discardWorkout()
      }
    }

    public func delete(externalID: String) async throws {
      guard let uuid = UUID(uuidString: externalID) else {
        throw WorkoutFixtureSourceError.notFound(WorkoutID(rawValue: externalID))
      }
      let descriptor = HKSampleQueryDescriptor<HKWorkout>(
        predicates: [.workout(HKQuery.predicateForObject(with: uuid))],
        sortDescriptors: [],
        limit: 1
      )
      guard let workout = try await descriptor.result(for: healthStore).first else {
        throw WorkoutFixtureSourceError.notFound(WorkoutID(rawValue: externalID))
      }
      try await healthStore.delete(workout)
    }

    private func makeSamples(from fixture: WorkoutFixture) -> [HKQuantitySample] {
      fixture.series.flatMap { series in
        let type = HealthKitTypes.quantityType(
          for: series.metric,
          activity: fixture.workout.activity
        )
        let unit = HealthKitTypes.unit(for: series.metric)
        return series.samples.map { sample in
          HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: unit, doubleValue: sample.value),
            start: sample.startDate,
            end: sample.endDate
          )
        }
      }
    }

    private func finish(_ builder: HKWorkoutBuilder) async throws -> HKWorkout? {
      try await withCheckedThrowingContinuation { continuation in
        builder.finishWorkout { workout, error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume(returning: workout)
          }
        }
      }
    }

    private func finish(
      _ builder: HKWorkoutRouteBuilder,
      with workout: HKWorkout
    ) async throws -> HKWorkoutRoute? {
      try await withCheckedThrowingContinuation { continuation in
        builder.finishRoute(with: workout, metadata: nil) { route, error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume(returning: route)
          }
        }
      }
    }
  }

  extension WorkoutEvent {
    fileprivate var healthKitEvent: HKWorkoutEvent {
      let type: HKWorkoutEventType =
        switch kind {
        case .pause: .pause
        case .resume: .resume
        case .lap: .lap
        case .segment: .segment
        case .marker: .marker
        }
      return HKWorkoutEvent(
        type: type,
        dateInterval: DateInterval(start: startDate, end: endDate),
        metadata: nil
      )
    }
  }

  extension RoutePoint {
    fileprivate var location: CLLocation {
      CLLocation(
        coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
        altitude: altitude ?? 0,
        horizontalAccuracy: horizontalAccuracy ?? 5,
        verticalAccuracy: verticalAccuracy ?? 5,
        course: course ?? -1,
        speed: speed ?? -1,
        timestamp: date
      )
    }
  }

  extension Array {
    fileprivate func chunked(into size: Int) -> [[Element]] {
      stride(from: 0, to: count, by: size).map {
        Array(self[$0..<Swift.min($0 + size, count)])
      }
    }
  }
#endif
