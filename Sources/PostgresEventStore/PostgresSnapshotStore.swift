import EventSourcing
import PostgresNIO

/// PostgreSQL-backed snapshot storage, separate from the event journal in the
/// same way Akka configures journal and snapshot-store plugins independently.
public actor PostgresSnapshotStore: SnapshotStore {
  private let client: PostgresClient

  public init(client: PostgresClient) {
    self.client = client
  }

  /// Keeps one snapshot per persistence ID, as akka-persistence-r2dbc does.
  /// The conditional upsert also preserves this package's monotonic contract:
  /// equal and out-of-order saves are no-ops.
  public func save<State: Codable & Sendable>(
    _ state: State,
    id: PersistenceID,
    coveredSequenceNumber: Int64
  ) async throws {
    let jsonb = JSONBEncoded(value: state)
    try await self.client.query(
      """
      INSERT INTO snapshots (persistence_id, sequence_number, state)
      VALUES (\(id), \(coveredSequenceNumber), \(jsonb))
      ON CONFLICT (persistence_id) DO UPDATE
        SET sequence_number = EXCLUDED.sequence_number,
            state = EXCLUDED.state,
            created_at = NOW()
        WHERE snapshots.sequence_number < EXCLUDED.sequence_number
      """
    )
  }

  public func latestSnapshot<State: Codable & Sendable>(
    id: PersistenceID
  ) async throws -> Snapshot<State>? {
    let rows = try await self.client.query(
      """
      SELECT sequence_number, state
      FROM snapshots
      WHERE persistence_id = \(id)
      LIMIT 1
      """
    )
    var iterator = rows.makeAsyncIterator()
    guard let row = try await iterator.next() else { return nil }
    guard let (sequenceNumber, jsonb) = try? row.decode((Int64, JSONBDecoded<State>).self) else {
      return nil
    }
    return Snapshot(
      state: jsonb.value,
      coveredSequenceNumber: sequenceNumber
    )
  }

  public func deleteSnapshots(
    id: PersistenceID,
    matching criteria: SnapshotSelectionCriteria
  ) async throws {
    switch (criteria.minSequenceNumber, criteria.maxSequenceNumber) {
    case (.some(let minimum), .some(let maximum)):
      try await self.client.query(
        """
        DELETE FROM snapshots
        WHERE persistence_id = \(id)
          AND sequence_number >= \(minimum)
          AND sequence_number <= \(maximum)
        """
      )
    case (.some(let minimum), .none):
      try await self.client.query(
        """
        DELETE FROM snapshots
        WHERE persistence_id = \(id) AND sequence_number >= \(minimum)
        """
      )
    case (.none, .some(let maximum)):
      try await self.client.query(
        """
        DELETE FROM snapshots
        WHERE persistence_id = \(id) AND sequence_number <= \(maximum)
        """
      )
    case (.none, .none):
      try await self.client.query(
        "DELETE FROM snapshots WHERE persistence_id = \(id)"
      )
    }
  }

  public func setupDatabase() async throws {
    try await self.client.query(
      """
      CREATE TABLE IF NOT EXISTS snapshots (
        persistence_id VARCHAR(255) NOT NULL PRIMARY KEY,
        sequence_number BIGINT      NOT NULL,
        state           JSONB       NOT NULL,
        created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
      """
    )
  }
}
