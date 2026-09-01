# Postgres Event Store

PostgreSQL implementations of `EventStore` and `SnapshotStore` for
[cluster-event-sourcing](https://github.com/akbashev/cluster-event-sourcing),
built directly on [PostgresNIO](https://github.com/vapor/postgres-nio).

The event journal is append-only and replay is streamed from PostgreSQL with
backpressure. Snapshots are optional and live in a separate table.

## Installation

```swift
dependencies: [
  .package(
    url: "https://github.com/akbashev/postgres-event-store.git",
    branch: "main"
  )
]
```

Add the product to your target and import it:

```swift
import DistributedCluster
import EventSourcing
import PostgresEventStore
import PostgresNIO
```

## Client and stores

Create one long-lived `PostgresClient` and share it between the journal and
snapshot store. The application must run the client for as long as either
store is in use:

```swift
let client = PostgresClient(
  configuration: .init(
    host: "localhost",
    username: "postgres",
    password: "postgres",
    database: "postgres",
    tls: .disable
  )
)

let clientTask = Task {
  await client.run()
}

let eventStore = PostgresEventStore(client: client)
let snapshotStore = PostgresSnapshotStore(client: client)

try await eventStore.setupDatabase()
try await snapshotStore.setupDatabase()
```

Keep `clientTask` alive with the application and cancel it during shutdown.
`setupDatabase()` uses `CREATE TABLE IF NOT EXISTS` and is convenient for local
development and tests. Production applications should manage schema changes
with their normal database migration tooling.

## Cluster integration

Install the cluster singleton before the journal plugin, then return the
already-created stores from its factories:

```swift
let system = await ClusterSystem("my-node") {
  $0.plugins.install(plugin: ClusterSingletonPlugin())
  $0.plugins.install(
    plugin: ClusterJournalPlugin(
      factory: { _ in eventStore },
      snapshotFactory: { _ in snapshotStore }
    )
  )
}
```

Omit `snapshotFactory` when snapshots are not required.

## Event journal semantics

`persistEvent(_:id:sequenceNumber:)` performs a plain SQL `INSERT`. The primary
key is `(persistence_id, sequence_number)`, so every attempt to reuse a
sequence number fails with PostgreSQL SQLSTATE `23505`, even when the payload
is identical. Writes are not retried, merged, or made idempotent by the store;
the entity recovers uncertain write outcomes by replaying its journal.

`eventStream(id:fromSequenceNumber:)` returns PostgresNIO's native asynchronous
query pipeline mapped to `EventEnvelope`. It reads rows in ascending sequence
order and does not materialize the complete journal in memory:

```swift
let stream: EventStream<OrderEvent> = try await eventStore.eventStream(
  id: "order-42",
  fromSequenceNumber: 10
)

for try await envelope in stream {
  print(envelope.sequenceNumber, envelope.event)
}
```

Events are encoded as PostgreSQL `JSONB` using their `Codable` conformance.

## Snapshot semantics

`PostgresSnapshotStore` keeps one row per persistence ID. Saving a snapshot
with a higher covered sequence number replaces the existing row; saving an
equal or lower sequence number is a no-op. This prevents an older actor
incarnation from replacing a newer snapshot.

Snapshot deletion accepts `SnapshotSelectionCriteria`. Because the store keeps
only the latest snapshot, deletion either leaves that row intact or removes it
when its sequence number matches the criteria. A snapshot payload that can no
longer be decoded as the requested state type is treated as absent so recovery
can fall back to the event journal.

## Testing

The integration tests expect PostgreSQL on `localhost`, use the current system
username, connect to the `postgres` database without a password, and disable
TLS:

```sh
swift test -Xswiftc -Xfrontend -Xswiftc -validate-tbd-against-ir=none
```
