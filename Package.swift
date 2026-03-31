// swift-tools-version: 6.2
import PackageDescription

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
    .package(url: "https://github.com/akbashev/cluster-event-sourcing.git", branch: "main"),
  ],
  targets: [
    .target(
      name: "PostgresEventStore",
      dependencies: [
        .product(name: "PostgresNIO", package: "postgres-nio"),
        .product(name: "EventSourcing", package: "cluster-event-sourcing"),
      ]
    ),
    .testTarget(
      name: "PostgresEventStoreTests",
      dependencies: [
        "PostgresEventStore"
      ]
    ),
  ]
)
