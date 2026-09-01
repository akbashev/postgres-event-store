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

  public init(
    client: PostgresClient
  ) {
    self.client = client
  }

  /// Persists an event for a given `PersistenceID`.
  ///
  /// A write is never retried or merged: any event already stored at
  /// `(id, sequenceNumber)` — identical or not — fails with the raw
  /// `PSQLError` (SQLSTATE `23505`, unique violation). The journal stays
  /// dumb on purpose (let-it-crash); whether a timed-out write actually
  /// landed is resolved by replaying the journal on entity recovery, not
  /// by SQL-level idempotency.
  public func persistEvent<Event>(_ event: Event, id: String, sequenceNumber: Int64) async throws where Event: Decodable, Event: Encodable, Event: Sendable {
    let jsonb = JSONBEncoded(value: event)
    try await self.client.query(
      """
      INSERT INTO journal (persistence_id, sequence_number, event)
      VALUES (\(id), \(sequenceNumber), \(jsonb))
      """
    )
  }

  /// Native `EventStore.eventStream`: PostgresNIO's row sequence supplies
  /// demand-driven iteration and adaptive, bounded row buffering.
  public func eventStream<Event: Codable & Sendable>(
    id: PersistenceID,
    fromSequenceNumber: Int64 = 1
  ) async throws -> EventStream<Event> {
    try await self.client.query(
      """
      SELECT sequence_number, event FROM journal
      WHERE persistence_id = \(id) AND sequence_number >= \(fromSequenceNumber)
      ORDER BY sequence_number ASC
      """
    )
    .decode((Int64, JSONBDecoded<Event>).self)
    .map { decoded in
      let (sequenceNumber, jsonb) = decoded
      return EventEnvelope(
        persistenceID: id,
        sequenceNumber: sequenceNumber,
        event: jsonb.value
      )
    }
  }

  public func setupDatabase() async throws {
    try await self.client.query(
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

    try await self.client.query(
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
