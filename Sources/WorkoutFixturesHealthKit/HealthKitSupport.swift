#if canImport(HealthKit)
  import Foundation
  import HealthKit
  import WorkoutFixtures

  /// Which HealthKit permissions to request for the workout types the adapters use
  /// (workouts, routes, heart rate, distance, active energy).
  public enum HealthKitWorkoutAccess: Sendable {
    case read
    case write
    case readWrite
  }

  /// Explicit authorization boundary, injectable so app code that requests
  /// authorization stays testable without a real `HKHealthStore`.
  public protocol HealthAuthorizing: Sendable {
    /// Requests the HealthKit permissions the adapters need for `access`.
    func requestAuthorization(for access: HealthKitWorkoutAccess) async throws
  }

  /// The production ``HealthAuthorizing``: asks a real `HKHealthStore` for access to every
  /// workout-related type the adapters read or write.
  public struct HealthKitAuthorizationController: HealthAuthorizing, Sendable {
    private let healthStore: HKHealthStore

    public init(healthStore: HKHealthStore) {
      self.healthStore = healthStore
    }

    /// Presents the system authorization sheet when any requested type is undetermined.
    /// - Throws: HealthKit errors, for example when Health data is unavailable on the device.
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

  /// A test double that always succeeds authorization without touching HealthKit.
  public struct AlwaysAuthorizedHealthAuthorizing: HealthAuthorizing, Sendable {
    public init() {}

    public func requestAuthorization(for access: HealthKitWorkoutAccess) async throws {}
  }

  /// A test double that always refuses authorization.
  public struct DenyingHealthAuthorizing: HealthAuthorizing, Sendable {
    public struct Denial: Error, Sendable, LocalizedError {
      public var errorDescription: String? {
        "HealthKit authorization was denied by DenyingHealthAuthorizing."
      }

      public init() {}
    }

    public init() {}

    public func requestAuthorization(for access: HealthKitWorkoutAccess) async throws {
      throw Denial()
    }
  }

  enum HealthKitTypes {
    static let workout = HKObjectType.workoutType()
    static let route = HKSeriesType.workoutRoute()
    static let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate)!
    static let walkingRunningDistance = HKObjectType.quantityType(
      forIdentifier: .distanceWalkingRunning)!
    static let cyclingDistance = HKObjectType.quantityType(forIdentifier: .distanceCycling)!
    static let swimmingDistance = HKObjectType.quantityType(forIdentifier: .distanceSwimming)!
    static let wheelchairDistance = HKObjectType.quantityType(forIdentifier: .distanceWheelchair)!
    static let downhillSnowSportsDistance = HKObjectType.quantityType(
      forIdentifier: .distanceDownhillSnowSports)!
    static let activeEnergy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!

    static let readTypes: Set<HKObjectType> = [
      workout, route, heartRate, walkingRunningDistance, cyclingDistance, swimmingDistance,
      wheelchairDistance, downhillSnowSportsDistance, activeEnergy,
    ]
    static let shareTypes: Set<HKSampleType> = [
      workout, route, heartRate, walkingRunningDistance, cyclingDistance, swimmingDistance,
      wheelchairDistance, downhillSnowSportsDistance, activeEnergy,
    ]

    static func distanceType(for activity: WorkoutActivity) -> HKQuantityType {
      switch activity {
      case .cycling, .handCycling:
        cyclingDistance
      case .swimming, .underwaterDiving, .waterFitness, .waterPolo:
        swimmingDistance
      case .wheelchairRunPace, .wheelchairWalkPace:
        wheelchairDistance
      case .downhillSkiing, .snowSports, .snowboarding:
        downhillSnowSportsDistance
      default:
        walkingRunningDistance
      }
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
    /// The `HKWorkoutActivityType` with the same name. The mapping is total
    /// and bijective (a test asserts `healthKitType.fixtureActivity == self`
    /// for every case).
    var healthKitType: HKWorkoutActivityType {
      switch self {
      case .americanFootball: .americanFootball
      case .archery: .archery
      case .australianFootball: .australianFootball
      case .badminton: .badminton
      case .barre: .barre
      case .baseball: .baseball
      case .basketball: .basketball
      case .bowling: .bowling
      case .boxing: .boxing
      case .cardioDance: .cardioDance
      case .climbing: .climbing
      case .cooldown: .cooldown
      case .coreTraining: .coreTraining
      case .cricket: .cricket
      case .crossCountrySkiing: .crossCountrySkiing
      case .crossTraining: .crossTraining
      case .curling: .curling
      case .cycling: .cycling
      case .dance: .dance
      case .discSports: .discSports
      case .downhillSkiing: .downhillSkiing
      case .elliptical: .elliptical
      case .equestrianSports: .equestrianSports
      case .fencing: .fencing
      case .fishing: .fishing
      case .fitnessGaming: .fitnessGaming
      case .flexibility: .flexibility
      case .functionalStrengthTraining: .functionalStrengthTraining
      case .golf: .golf
      case .gymnastics: .gymnastics
      case .handCycling: .handCycling
      case .handball: .handball
      case .highIntensityIntervalTraining: .highIntensityIntervalTraining
      case .hiking: .hiking
      case .hockey: .hockey
      case .hunting: .hunting
      case .jumpRope: .jumpRope
      case .kickboxing: .kickboxing
      case .lacrosse: .lacrosse
      case .martialArts: .martialArts
      case .mindAndBody: .mindAndBody
      case .mixedCardio: .mixedCardio
      case .paddleSports: .paddleSports
      case .pickleball: .pickleball
      case .pilates: .pilates
      case .play: .play
      case .preparationAndRecovery: .preparationAndRecovery
      case .racquetball: .racquetball
      case .rowing: .rowing
      case .rugby: .rugby
      case .running: .running
      case .sailing: .sailing
      case .skatingSports: .skatingSports
      case .snowSports: .snowSports
      case .snowboarding: .snowboarding
      case .soccer: .soccer
      case .socialDance: .socialDance
      case .softball: .softball
      case .squash: .squash
      case .stairClimbing: .stairClimbing
      case .stairs: .stairs
      case .stepTraining: .stepTraining
      case .surfingSports: .surfingSports
      case .swimBikeRun: .swimBikeRun
      case .swimming: .swimming
      case .tableTennis: .tableTennis
      case .taiChi: .taiChi
      case .tennis: .tennis
      case .trackAndField: .trackAndField
      case .traditionalStrengthTraining: .traditionalStrengthTraining
      case .transition: .transition
      case .underwaterDiving: .underwaterDiving
      case .volleyball: .volleyball
      case .walking: .walking
      case .waterFitness: .waterFitness
      case .waterPolo: .waterPolo
      case .waterSports: .waterSports
      case .wheelchairRunPace: .wheelchairRunPace
      case .wheelchairWalkPace: .wheelchairWalkPace
      case .wrestling: .wrestling
      case .yoga: .yoga
      }
    }
  }

  extension HKWorkoutActivityType {
    /// The fixture activity with the same name; `nil` for deprecated or
    /// future HealthKit types the schema does not represent.
    var fixtureActivity: WorkoutActivity? {
      // HKWorkoutActivityType is not CaseIterable, so the reverse mapping
      // round-trips through the shared names via the forward mapping.
      Self.fixtureActivitiesByRawValue[rawValue]
    }

    private static let fixtureActivitiesByRawValue: [UInt: WorkoutActivity] =
      Dictionary(
        uniqueKeysWithValues: WorkoutActivity.allCases.map { ($0.healthKitType.rawValue, $0) }
      )
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
