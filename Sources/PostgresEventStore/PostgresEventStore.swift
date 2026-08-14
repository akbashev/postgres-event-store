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
  public func persistEvent<Event>(_ event: Event, id: String, sequenceNumber: Int64) async throws where Event: Decodable, Event: Encodable, Event: Sendable {
    let jsonb = JSONBEncoded(value: event)
    try await self.client.query(
      """
      INSERT INTO journal (persistence_id, sequence_number, event)
      VALUES (\(id), \(sequenceNumber), \(jsonb))
      """
    )
  }

  public func eventsFor<Event: Sendable & Codable>(id: PersistenceID, fromSequenceNumber: Int64) async throws -> [Event] {
    try await self.client.query(
      "SELECT event FROM journal WHERE persistence_id = \(id) AND sequence_number >= \(fromSequenceNumber) ORDER BY sequence_number ASC"
    )
    .decode(JSONBDecoded<Event>.self)
    .reduce(into: []) { $0.append($1.value) }
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

private struct JSONBEncoded<T: Encodable>: PostgresEncodable {
  static var psqlType: PostgresDataType { .jsonb }
  static var psqlFormat: PostgresFormat { .text }

  let value: T

  func encode(
    into byteBuffer: inout ByteBuffer,
    context: PostgresEncodingContext<some PostgresJSONEncoder>
  ) throws {
    let data = try context.jsonEncoder.encode(value)
    byteBuffer.writeBytes(data)
  }
}

private struct JSONBDecoded<T: Decodable & Sendable>: PostgresDecodable, Sendable {
  static var psqlType: PostgresDataType { .jsonb }
  static var psqlFormat: PostgresFormat { .text }

  let value: T

  init(
    from buffer: inout ByteBuffer,
    type: PostgresDataType,
    format: PostgresFormat,
    context: PostgresDecodingContext<some PostgresJSONDecoder>
  ) throws {
    _ = buffer.readInteger(as: UInt8.self)
    self.value = try context.jsonDecoder.decode(T.self, from: buffer)
  }
}
