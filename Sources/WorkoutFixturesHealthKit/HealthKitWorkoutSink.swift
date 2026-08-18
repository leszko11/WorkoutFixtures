#if canImport(HealthKit)
  import CoreLocation
  import Foundation
  import HealthKit
  import WorkoutFixtures

  /// Failures specific to writing fixtures into HealthKit.
  public enum HealthKitImportError: Error, Equatable, Sendable, LocalizedError {
    /// The workout saved but HealthKit returned no object to attach the route to; thrown only
    /// for fixtures with a route (routeless saves report `.savedUnavailable` instead).
    case finishReturnedNoWorkout
    /// The route finished saving but HealthKit returned no route object.
    case finishReturnedNoRoute

    public var errorDescription: String? {
      switch self {
      case .finishReturnedNoWorkout:
        "HealthKit finished saving but the workout is temporarily unavailable."
      case .finishReturnedNoRoute:
        "HealthKit finished saving but the workout route is temporarily unavailable."
      }
    }
  }

  /// A store failure whose rollback also failed, so HealthKit may retain partial data.
  public struct HealthKitStoreFailure: Error, Sendable, LocalizedError {
    /// The error that made the store attempt fail.
    public let underlying: any Error
    /// The error that prevented deleting the already-persisted workout or samples.
    public let cleanupError: any Error

    public var errorDescription: String? {
      "Import failed (\(underlying.localizedDescription)); "
        + "rollback also failed (\(cleanupError.localizedDescription))."
    }
  }

  /// Writes fixtures into HealthKit via `HKWorkoutBuilder` and deletes them by UUID.
  ///
  /// Samples are added in chunks of 500 (route locations in chunks of 100), with cancellation
  /// checked between chunks. If anything fails after the workout has been persisted, the sink
  /// rolls back by deleting the saved samples and workout; failures before persistence discard
  /// the builder, leaving HealthKit untouched. A failed rollback surfaces as
  /// ``HealthKitStoreFailure``.
  public actor HealthKitWorkoutSink: WorkoutFixtureSink, WorkoutFixtureDeleting {
    private let healthStore: HKHealthStore
    private let validator: WorkoutValidator

    /// Creates a sink over `healthStore`; every fixture must pass `validator` before writing.
    public init(
      healthStore: HKHealthStore,
      validator: WorkoutValidator = WorkoutValidator()
    ) {
      self.healthStore = healthStore
      self.validator = validator
    }

    /// Validates `fixture` and saves it as a new HealthKit workout with its samples, events,
    /// route, and time-zone metadata.
    ///
    /// The receipt's `externalID` is the HealthKit workout UUID; a `savedUnavailable` status
    /// means HealthKit saved the workout but did not return it. Cancellation between chunks
    /// aborts the import and rolls back like any other failure.
    /// - Throws: `FixtureValidationError` when the fixture is invalid,
    ///   ``HealthKitImportError`` when a builder misbehaves, ``HealthKitStoreFailure`` when
    ///   rollback fails after partial persistence, `CancellationError`, or HealthKit errors
    ///   (e.g. missing authorization).
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
      var routeBuilder: HKWorkoutRouteBuilder?
      var savedWorkout: HKWorkout?
      // Builders raise an unrecoverable NSException when discarded after a
      // finish call, so rollback must skip discarding once finishing started.
      var workoutFinishAttempted = false
      var routeFinishAttempted = false

      // Cancellation is cooperative only: every builder call happens inside this
      // actor-isolated method, and a thrown CancellationError reaches the single
      // rollback path below. An onCancel handler would race in-flight builder calls.
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
          // A standalone route builder is finished explicitly with the saved
          // workout below. Do not use `builder.seriesBuilder(for:)`: that
          // attached builder is finished by the workout builder itself, and
          // finishing it manually raises.
          let builder = HKWorkoutRouteBuilder(healthStore: healthStore, device: nil)
          routeBuilder = builder
          for chunk in route.points.map(\.location).chunked(into: 100) {
            try Task.checkCancellation()
            try await builder.insertRouteData(chunk)
          }
        }
        var metadata: [String: Any] = [
          HKMetadataKeyTimeZone: fixture.workout.timeZoneIdentifier
        ]
        if fixture.workout.location != .unknown {
          metadata[HKMetadataKeyIndoorWorkout] = fixture.workout.location == .indoor
        }
        try await builder.addMetadata(metadata)
        try Task.checkCancellation()
        try await builder.endCollection(at: fixture.workout.endDate)
        workoutFinishAttempted = true
        let workout = try await finish(builder)
        savedWorkout = workout
        try Task.checkCancellation()
        if let activeRouteBuilder = routeBuilder {
          guard let workout else {
            throw HealthKitImportError.finishReturnedNoWorkout
          }
          routeFinishAttempted = true
          guard try await finish(activeRouteBuilder, with: workout) != nil else {
            throw HealthKitImportError.finishReturnedNoRoute
          }
          routeBuilder = nil
          try Task.checkCancellation()
        }
        return StoredWorkout(
          fixtureID: fixture.id,
          externalID: workout?.uuid.uuidString,
          storedAt: fixture.workout.endDate,
          status: workout == nil ? .savedUnavailable : .available
        )
      } catch {
        if !routeFinishAttempted {
          routeBuilder?.discard()
        }
        if let savedWorkout {
          // The workout is already persisted; the builder must not be discarded
          // after a successful finish. Remove children before the parent, and
          // attempt the parent even if the children fail.
          var cleanupFailure: (any Error)?
          if !samples.isEmpty {
            do {
              try await healthStore.delete(samples)
            } catch let deleteError {
              cleanupFailure = deleteError
            }
          }
          do {
            try await healthStore.delete(savedWorkout)
          } catch let deleteError {
            cleanupFailure = cleanupFailure ?? deleteError
          }
          if let cleanupFailure {
            throw HealthKitStoreFailure(underlying: error, cleanupError: cleanupFailure)
          }
        } else if !workoutFinishAttempted {
          builder.discardWorkout()
        }
        throw error
      }
    }

    /// Deletes the HealthKit workout whose UUID matches `externalID`.
    /// - Throws: `WorkoutFixtureSourceError.notFound` when the ID is not a UUID or no workout
    ///   matches; HealthKit errors when the deletion itself fails.
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
    func chunked(into size: Int) -> [[Element]] {
      stride(from: 0, to: count, by: size).map {
        Array(self[$0..<Swift.min($0 + size, count)])
      }
    }
  }
#endif
