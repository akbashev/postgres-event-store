import EventSourcing
import PostgresNIO
import Testing

@testable import PostgresEventStore

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@Suite("PostgresEventStore Tests", .serialized)
struct PostgresEventStoreTests {

  struct TestEvent: Codable, Sendable, Equatable {
    let value: String
  }

  struct TestState: Codable, Sendable, Equatable {
    let value: String
  }

  private func makeStore() -> (PostgresEventStore, PostgresClient) {
    let client = PostgresClient(
      configuration: PostgresClient.Configuration(
        host: "localhost",
        username: NSUserName(),
        password: nil,
        database: "postgres",
        tls: .disable
      )
    )
    return (PostgresEventStore(client: client), client)
  }

  private func makeSnapshotStore() -> (PostgresSnapshotStore, PostgresClient) {
    let client = PostgresClient(
      configuration: PostgresClient.Configuration(
        host: "localhost",
        username: NSUserName(),
        password: nil,
        database: "postgres",
        tls: .disable
      )
    )
    return (PostgresSnapshotStore(client: client), client)
  }

  @Test("Save, load, and delete snapshots by criteria")
  func snapshots() async throws {
    let (store, client) = self.makeSnapshotStore()
    let persistenceID = "snapshot-test-\(UUID().uuidString)"

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await client.run() }
      defer { group.cancelAll() }

      try await store.setupDatabase()
      defer {
        _ = try? await client.query(
          "DELETE FROM snapshots WHERE persistence_id = \(persistenceID)"
        )
      }

      try await store.save(
        TestState(value: "one"),
        id: persistenceID,
        coveredSequenceNumber: 1
      )
      // Equal and lower sequence numbers are monotonic no-ops.
      try await store.save(
        TestState(value: "replacement"),
        id: persistenceID,
        coveredSequenceNumber: 1
      )
      try await store.save(
        TestState(value: "three"),
        id: persistenceID,
        coveredSequenceNumber: 3
      )
      try await store.save(
        TestState(value: "two"),
        id: persistenceID,
        coveredSequenceNumber: 2
      )

      var latest: Snapshot<TestState>? = try await store.latestSnapshot(id: persistenceID)
      #expect(latest?.coveredSequenceNumber == 3)
      #expect(latest?.state == TestState(value: "three"))

      try await store.deleteSnapshots(
        id: persistenceID,
        matching: .init(minSequenceNumber: 1, maxSequenceNumber: 2)
      )
      latest = try await store.latestSnapshot(id: persistenceID)
      #expect(latest?.coveredSequenceNumber == 3)
      #expect(latest?.state == TestState(value: "three"))

      try await store.deleteSnapshots(id: persistenceID, matching: .through(3))
      latest = try await store.latestSnapshot(id: persistenceID)
      #expect(latest?.coveredSequenceNumber == nil)
    }
  }

  @Test("An undecodable latest snapshot is treated as absent")
  func undecodableSnapshot() async throws {
    let (store, client) = self.makeSnapshotStore()
    let persistenceID = "snapshot-decode-test-\(UUID().uuidString)"

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await client.run() }
      defer { group.cancelAll() }

      try await store.setupDatabase()
      defer {
        _ = try? await client.query(
          "DELETE FROM snapshots WHERE persistence_id = \(persistenceID)"
        )
      }

      try await client.query(
        """
        INSERT INTO snapshots (persistence_id, sequence_number, state)
        VALUES (\(persistenceID), 1, '{"unexpected":true}'::jsonb)
        """
      )

      let latest: Snapshot<TestState>? = try await store.latestSnapshot(id: persistenceID)
      #expect(latest?.coveredSequenceNumber == nil)
    }
  }

  @Test("Persist and replay events")
  func persistAndReplay() async throws {
    let (store, client) = self.makeStore()
    let persistenceID = "test-\(UUID().uuidString)"

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await client.run() }
      // Defers run LIFO: the DELETE executes first (client still running),
      // then cancelAll shuts the client down so the group can exit.
      defer { group.cancelAll() }

      try await store.setupDatabase()
      defer {
        _ = try? await client.query(
          "DELETE FROM journal WHERE persistence_id = \(persistenceID)"
        )
      }

      for sequenceNumber: Int64 in 1...3 {
        try await store.persistEvent(
          TestEvent(value: "event-\(sequenceNumber)"),
          id: persistenceID,
          sequenceNumber: sequenceNumber
        )
      }

      let events: [TestEvent] = try await store.eventsFor(id: persistenceID)
      #expect(events == (1...3).map { TestEvent(value: "event-\($0)") })
    }
  }

  @Test("Stream events with metadata from a sequence number")
  func eventStream() async throws {
    let (store, client) = self.makeStore()
    let persistenceID = "test-\(UUID().uuidString)"

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await client.run() }
      defer { group.cancelAll() }

      try await store.setupDatabase()
      defer {
        _ = try? await client.query(
          "DELETE FROM journal WHERE persistence_id = \(persistenceID)"
        )
      }

      for sequenceNumber: Int64 in 1...3 {
        try await store.persistEvent(
          TestEvent(value: "event-\(sequenceNumber)"),
          id: persistenceID,
          sequenceNumber: sequenceNumber
        )
      }

      var envelopes: [EventEnvelope<TestEvent>] = []
      let stream: EventStream<TestEvent> = try await store.eventStream(id: persistenceID, fromSequenceNumber: 2)
      for try await envelope in stream {
        envelopes.append(envelope)
      }

      #expect(envelopes.map(\.sequenceNumber) == [2, 3])
      #expect(envelopes.map(\.persistenceID) == [persistenceID, persistenceID])
      #expect(envelopes.map(\.event.value) == ["event-2", "event-3"])
    }
  }

  @Test("Persisting the same event twice fails unconditionally")
  func duplicatePersist() async throws {
    let (store, client) = self.makeStore()
    let persistenceID = "test-\(UUID().uuidString)"

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await client.run() }
      defer { group.cancelAll() }

      try await store.setupDatabase()
      defer {
        _ = try? await client.query(
          "DELETE FROM journal WHERE persistence_id = \(persistenceID)"
        )
      }

      let event = TestEvent(value: "event-1")
      try await store.persistEvent(event, id: persistenceID, sequenceNumber: 1)

      // Let-it-crash: even an identical rewrite is a conflict — idempotency
      // is resolved by journal replay on recovery, not by the store.
      do {
        try await store.persistEvent(event, id: persistenceID, sequenceNumber: 1)
        Issue.record("Expected a unique violation")
      } catch let error as PSQLError {
        #expect(error.serverInfo?[.sqlState] == "23505")
      }

      let events: [TestEvent] = try await store.eventsFor(id: persistenceID)
      #expect(events == [event])
    }
  }

  @Test("Persisting a different event at the same sequence number fails")
  func conflictingPersist() async throws {
    let (store, client) = self.makeStore()
    let persistenceID = "test-\(UUID().uuidString)"

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await client.run() }
      defer { group.cancelAll() }

      try await store.setupDatabase()
      defer {
        _ = try? await client.query(
          "DELETE FROM journal WHERE persistence_id = \(persistenceID)"
        )
      }

      try await store.persistEvent(
        TestEvent(value: "original"),
        id: persistenceID,
        sequenceNumber: 1
      )

      do {
        try await store.persistEvent(
          TestEvent(value: "different"),
          id: persistenceID,
          sequenceNumber: 1
        )
        Issue.record("Expected a unique violation")
      } catch let error as PSQLError {
        #expect(error.serverInfo?[.sqlState] == "23505")
      }

      let events: [TestEvent] = try await store.eventsFor(id: persistenceID)
      #expect(events == [TestEvent(value: "original")])
    }
  }
}
