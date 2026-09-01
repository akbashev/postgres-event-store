import PostgresNIO

struct JSONBEncoded<Value: Encodable>: PostgresEncodable {
  static var psqlType: PostgresDataType { .jsonb }
  static var psqlFormat: PostgresFormat { .text }

  let value: Value

  func encode(
    into byteBuffer: inout ByteBuffer,
    context: PostgresEncodingContext<some PostgresJSONEncoder>
  ) throws {
    let data = try context.jsonEncoder.encode(self.value)
    byteBuffer.writeBytes(data)
  }
}

struct JSONBDecoded<Value: Decodable & Sendable>: PostgresDecodable, Sendable {
  static var psqlType: PostgresDataType { .jsonb }
  static var psqlFormat: PostgresFormat { .text }

  let value: Value

  init(
    from buffer: inout ByteBuffer,
    type: PostgresDataType,
    format: PostgresFormat,
    context: PostgresDecodingContext<some PostgresJSONDecoder>
  ) throws {
    _ = buffer.readInteger(as: UInt8.self)
    self.value = try context.jsonDecoder.decode(Value.self, from: buffer)
  }
}
