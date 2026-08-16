#if canImport(HealthKit)
  import Foundation
  import HealthKit
  import WorkoutFixtures

  public enum HealthKitWorkoutAccess: Sendable {
    case read
    case write
    case readWrite
  }

  /// Explicit authorization boundary, injectable so app code that requests
  /// authorization stays testable without a real `HKHealthStore`.
  public protocol HealthAuthorizing: Sendable {
    func requestAuthorization(for access: HealthKitWorkoutAccess) async throws
  }

  public struct HealthKitAuthorizationController: HealthAuthorizing, Sendable {
    private let healthStore: HKHealthStore

    public init(healthStore: HKHealthStore) {
      self.healthStore = healthStore
    }

    public func requestAuthorization(for access: HealthKitWorkoutAccess) async throws {
      let shareTypes: Set<HKSampleType>
      let readTypes: Set<HKObjectType>
      switch access {
      case .read:
        shareTypes = []
        readTypes = HealthKitTypes.readTypes
      case .write:
        shareTypes = HealthKitTypes.shareTypes
        readTypes = []
      case .readWrite:
        shareTypes = HealthKitTypes.shareTypes
        readTypes = HealthKitTypes.readTypes
      }
      try await healthStore.requestAuthorization(toShare: shareTypes, read: readTypes)
    }
  }

  enum HealthKitTypes {
    static let workout = HKObjectType.workoutType()
    static let route = HKSeriesType.workoutRoute()
    static let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate)!
    static let walkingRunningDistance = HKObjectType.quantityType(
      forIdentifier: .distanceWalkingRunning)!
    static let cyclingDistance = HKObjectType.quantityType(forIdentifier: .distanceCycling)!
    static let activeEnergy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!

    static let readTypes: Set<HKObjectType> = [
      workout, route, heartRate, walkingRunningDistance, cyclingDistance, activeEnergy,
    ]
    static let shareTypes: Set<HKSampleType> = [
      workout, route, heartRate, walkingRunningDistance, cyclingDistance, activeEnergy,
    ]

    static func distanceType(for activity: WorkoutActivity) -> HKQuantityType {
      activity == .cycling ? cyclingDistance : walkingRunningDistance
    }

    static func quantityType(for metric: MetricIdentifier, activity: WorkoutActivity)
      -> HKQuantityType
    {
      switch metric {
      case .heartRate: heartRate
      case .distance: distanceType(for: activity)
      case .activeEnergy: activeEnergy
      }
    }

    static func unit(for metric: MetricIdentifier) -> HKUnit {
      HKUnit(from: metric.canonicalUnit.rawValue)
    }
  }

  extension WorkoutActivity {
    var healthKitType: HKWorkoutActivityType {
      switch self {
      case .running: .running
      case .walking: .walking
      case .cycling: .cycling
      }
    }
  }

  extension HKWorkoutActivityType {
    var fixtureActivity: WorkoutActivity? {
      switch self {
      case .running: .running
      case .walking: .walking
      case .cycling: .cycling
      default: nil
      }
    }
  }

  extension WorkoutLocation {
    var healthKitType: HKWorkoutSessionLocationType {
      switch self {
      case .indoor: .indoor
      case .outdoor: .outdoor
      case .unknown: .unknown
      }
    }
  }

  extension HKWorkout {
    var fixtureLocation: WorkoutLocation {
      guard let indoor = metadata?[HKMetadataKeyIndoorWorkout] as? Bool else { return .unknown }
      return indoor ? .indoor : .outdoor
    }
  }
#endif
