import EventSourcing
import PostgresNIO

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public actor PostgresEventStore: EventStore {

  public typealias PersistenceID = String

  private let client: PostgresClient
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(
    client: PostgresClient,
    encoder: JSONEncoder = .init(),
    decoder: JSONDecoder = .init()
  ) {
    self.client = client
    self.encoder = encoder
    self.decoder = decoder
  }

  /// Persists an event for a given `PersistenceID`.
  public func persistEvent<Event: Sendable & Codable>(
    _ event: Event,
    id: PersistenceID
  ) async throws {
    let data = try self.encoder.encode(event)
    guard let jsonb = String(data: data, encoding: .utf8) else {
      throw PostgresEventStoreError.invalidData
    }
    try await self.client.query(
      """
      WITH next_seq AS (
          SELECT COALESCE(MAX(sequence_number), 0) + 1 AS seq
          FROM journal WHERE persistence_id = \(id)
      )
      INSERT INTO journal (persistence_id, sequence_number, event)
      SELECT \(id), seq, \(jsonb)::jsonb
      FROM next_seq
      """
    )
  }

  public func eventsFor<Event: Sendable & Codable>(id: PersistenceID) async throws -> [Event] {
    let rows = try await client.query(
      "SELECT event FROM journal WHERE persistence_id = \(id) ORDER BY sequence_number ASC"
    )

    var events: [Event] = []
    for try await (jsonString) in rows.decode(String.self) {
      let data = Data(jsonString.utf8)
      let event = try decoder.decode(Event.self, from: data)
      events.append(event)
    }
    return events
  }

  public func setupDatabase() async throws {
    try await client.query(
      """
      CREATE TABLE IF NOT EXISTS journal (
          persistence_id  VARCHAR(255) NOT NULL,
          sequence_number BIGINT       NOT NULL,
          event           JSONB        NOT NULL,
          created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
          PRIMARY KEY (persistence_id, sequence_number)
      )
      """
    )

    try await client.query(
      """
      CREATE INDEX IF NOT EXISTS journal_persistence_id_idx
      ON journal (persistence_id)
      """
    )
  }
}

public enum PostgresEventStoreError: Swift.Error {
  case invalidData
}
