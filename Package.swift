// swift-tools-version: 6.2

import PackageDescription

let concurrencySettings: [SwiftSetting] = [
  .enableExperimentalFeature("StrictConcurrency=complete"),
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
  name: "WorkoutFixtures",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
    .watchOS(.v10),
  ],
  products: [
    .library(name: "WorkoutFixtures", targets: ["WorkoutFixtures"]),
    .library(name: "WorkoutFixturesHealthKit", targets: ["WorkoutFixturesHealthKit"]),
    .library(name: "WorkoutFixturesTestSupport", targets: ["WorkoutFixturesTestSupport"]),
    .executable(name: "workout-fixture", targets: ["WorkoutFixtureCLI"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/apple/swift-argument-parser.git",
      from: "1.8.2"
    )
  ],
  targets: [
    .target(
      name: "WorkoutFixtures",
      resources: [.process("Resources")],
      swiftSettings: concurrencySettings
    ),
    .target(
      name: "WorkoutFixturesHealthKit",
      dependencies: ["WorkoutFixtures"],
      swiftSettings: concurrencySettings
    ),
    .target(
      name: "WorkoutFixturesTestSupport",
      dependencies: ["WorkoutFixtures"],
      resources: [.process("Resources")],
      swiftSettings: concurrencySettings
    ),
    .executableTarget(
      name: "WorkoutFixtureCLI",
      dependencies: [
        "WorkoutFixtures",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      swiftSettings: concurrencySettings
    ),
    .testTarget(
      name: "WorkoutFixturesTests",
      dependencies: ["WorkoutFixtures", "WorkoutFixturesTestSupport"],
      swiftSettings: concurrencySettings
    ),
    .testTarget(
      name: "WorkoutFixturesHealthKitTests",
      dependencies: ["WorkoutFixturesHealthKit", "WorkoutFixturesTestSupport"],
      swiftSettings: concurrencySettings
    ),
    .testTarget(
      name: "WorkoutFixtureCLITests",
      dependencies: ["WorkoutFixtureCLI", "WorkoutFixturesTestSupport"],
      swiftSettings: concurrencySettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
