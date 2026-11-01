import EventSourcing
import PostgresNIO

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public actor PostgresEventStore: EventStore {

  public typealias PersistenceID = String

  /// The advisory lock every write to the journal takes for its transaction ("journal" in
  /// ASCII): writes are kept one at a time, so each event's ordering is committed before the
  /// next is given out.
  static let orderingLock: Int64 = 0x6A_6F75_726E_616C

  private let client: PostgresClient
  private let logger: Logger

  public init(
    client: PostgresClient,
    logger: Logger = Logger(label: "postgres-event-store")
  ) {
    self.client = client
    self.logger = logger
  }

  /// Persists an event for a given `PersistenceID`, with its tags, in one row.
  ///
  /// Each write takes `orderingLock` for its transaction, so writes are kept one at a time:
  /// an ordering is committed, or rolled back, before the next is given out, and a reader that
  /// sees an event never misses one with a lower offset that commits later. That makes the
  /// journal's writes one at a time across every node.
  ///
  /// A write is never retried or merged: any event already stored at
  /// `(id, sequenceNumber)` — identical or not — fails with the raw
  /// `PSQLError` (SQLSTATE `23505`, unique violation). The journal stays
  /// dumb on purpose (let-it-crash); whether a timed-out write actually
  /// landed is resolved by replaying the journal on entity recovery, not
  /// by SQL-level idempotency.
  public func persistEvent<Event>(_ event: Event, id: String, sequenceNumber: Int64, tags: Set<EventTag>) async throws
  where Event: Decodable, Event: Encodable, Event: Sendable {
    let jsonb = JSONBEncoded(value: event)
    let tags = tags.map(\.rawValue).sorted()
    let logger = self.logger
    do {
      try await self.client.withTransaction(logger: logger) { connection in
        try await connection.query("SELECT pg_advisory_xact_lock(\(Self.orderingLock))", logger: logger)
        try await connection.query(
          """
          INSERT INTO journal (persistence_id, sequence_number, event, tags)
          VALUES (\(id), \(sequenceNumber), \(jsonb), \(tags))
          """,
          logger: logger
        )
      }
    } catch let error as PostgresTransactionError {
      // A write refused and rolled back fails as the server said; a transaction that couldn't
      // begin, commit or roll back fails as that.
      guard error.beginError == nil, error.rollbackError == nil, error.commitError == nil,
        let refused = error.closureError
      else { throw error }
      throw refused
    }
  }

  /// Native `EventStore.eventStream`: PostgresNIO's row sequence supplies
  /// demand-driven iteration and adaptive, bounded row buffering.
  public func eventStream<Event: Codable & Sendable>(
    id: PersistenceID,
    fromSequenceNumber: Int64 = 1
  ) async throws -> EventStream<Event> {
    try await self.client.query(
      """
      SELECT ordering, sequence_number, event FROM journal
      WHERE persistence_id = \(id) AND sequence_number >= \(fromSequenceNumber)
      ORDER BY sequence_number ASC
      """
    )
    .decode((Int64, Int64, JSONBDecoded<Event>).self)
    .map { decoded in
      let (ordering, sequenceNumber, jsonb) = decoded
      return EventEnvelope(
        persistenceID: id,
        sequenceNumber: sequenceNumber,
        offset: Offset(ordering),
        event: jsonb.value
      )
    }
  }

  /// Native `EventStore.currentEventsByTag`, through the tags' index, with the same
  /// demand-driven iteration as `eventStream`.
  public func currentEventsByTag<Event: Codable & Sendable>(
    _ tag: EventTag,
    after offset: Offset
  ) async throws -> EventStream<Event> {
    try await self.client.query(
      """
      SELECT ordering, persistence_id, sequence_number, event FROM journal
      WHERE tags @> \([tag.rawValue]) AND ordering > \(offset.rawValue)
      ORDER BY ordering ASC
      """
    )
    .decode((Int64, String, Int64, JSONBDecoded<Event>).self)
    .map { decoded in
      let (ordering, persistenceID, sequenceNumber, jsonb) = decoded
      return EventEnvelope(
        persistenceID: persistenceID,
        sequenceNumber: sequenceNumber,
        offset: Offset(ordering),
        event: jsonb.value
      )
    }
  }

  public func setupDatabase() async throws {
    try await self.client.query(
      """
      CREATE TABLE IF NOT EXISTS journal (
          ordering        BIGSERIAL    NOT NULL UNIQUE,
          persistence_id  VARCHAR(255) NOT NULL,
          sequence_number BIGINT       NOT NULL,
          event           JSONB        NOT NULL,
          tags            TEXT[]       NOT NULL DEFAULT '{}',
          created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
          PRIMARY KEY (persistence_id, sequence_number)
      )
      """
    )

    // Every tag's events: what a read by tag scans.
    try await self.client.query(
      """
      CREATE INDEX IF NOT EXISTS journal_tags_idx
      ON journal USING GIN (tags)
      """
    )
  }
}

public enum PostgresEventStoreError: Swift.Error {
  case invalidData
}
