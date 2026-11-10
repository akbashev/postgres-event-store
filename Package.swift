// swift-tools-version: 6.4
import PackageDescription

/// The language as Swift 7 will have it, for every target.
let swiftSettings: [SwiftSetting] = [
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("ImmutableWeakCaptures"),
  .enableUpcomingFeature("InferIsolatedConformances"),
  .enableUpcomingFeature("InternalImportsByDefault"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
  name: "postgres-event-store",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .library(name: "PostgresEventStore", targets: ["PostgresEventStore"])
  ],
  dependencies: [
    .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.27.0"),
    .package(url: "https://github.com/akbashev/cluster-event-sourcing.git", branch: "turgai-integration"),
  ],
  targets: [
    .target(
      name: "PostgresEventStore",
      dependencies: [
        .product(name: "PostgresNIO", package: "postgres-nio"),
        .product(name: "EventSourcing", package: "cluster-event-sourcing"),
      ],
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "PostgresEventStoreTests",
      dependencies: [
        "PostgresEventStore"
      ],
      swiftSettings: swiftSettings
    ),
  ]
)
