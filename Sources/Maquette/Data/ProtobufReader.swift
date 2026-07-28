import Foundation

/// Something a protobuf message can be wrong in.
enum ProtobufError: Error, Equatable {
    /// The message ended in the middle of a value.
    case truncated
    /// A varint that never terminated inside the ten bytes a 64-bit value can occupy.
    case malformedVarint
    /// Wire types 3 and 4 — groups, deprecated since proto2 and absent from the vector tile
    /// schema. A message using them is not one this reader was written for.
    case unsupportedWireType(UInt8)
}

/// Reads the protocol-buffers wire format directly.
///
/// Vector tiles are protobuf, and this package takes no dependencies, so rather than bring in a
/// code generator and its runtime this reads the wire format by hand. That is a smaller thing than
/// it sounds. The format is self-describing enough to skip what it does not recognise: every field
/// is prefixed by a key naming its number and one of four length rules, so a reader needs varints,
/// those four rules, and nothing else. Field *names*, types and required-ness live only in the
/// `.proto` file, which is why the meaning has to come from somewhere — here, `VectorTile`.
///
/// Nothing in this type knows what a tile is.
///
/// ## Sub-messages are views, not copies
///
/// A length-delimited field holds a nested message, and `message()` hands back a reader bounded to
/// those bytes rather than slicing them out. The tiles this runs against are a few hundred
/// kilobytes containing thousands of nested features, so copying each one out would cost more than
/// the parse.
struct ProtobufReader {
    /// How a field's value is laid out, from the low three bits of its key.
    enum WireType: UInt8 {
        /// A varint: `int32`, `int64`, `uint*`, `sint*`, `bool`, enums.
        case varint = 0
        /// Eight bytes: `fixed64`, `sfixed64`, `double`.
        case fixed64 = 1
        /// A varint length followed by that many bytes: `string`, `bytes`, sub-messages, and any
        /// packed repeated scalar.
        case lengthDelimited = 2
        /// Four bytes: `fixed32`, `sfixed32`, `float`.
        case fixed32 = 5
    }

    private let bytes: [UInt8]
    private var index: Int
    private let end: Int

    init(_ data: Data) {
        self.bytes = [UInt8](data)
        self.index = 0
        self.end = self.bytes.count
    }

    private init(bytes: [UInt8], from: Int, to: Int) {
        self.bytes = bytes
        self.index = from
        self.end = to
    }

    /// Whether any field remains in this message.
    var hasMore: Bool { index < end }

    /// Reads the next field's key. Returns `nil` at the end of the message.
    ///
    /// The value is *not* read — the caller must either consume it with one of the readers below or
    /// hand the wire type to `skip(_:)`. Leaving it unread desynchronises the stream.
    mutating func nextField() throws -> (number: Int, wire: WireType)? {
        guard hasMore else { return nil }
        let key = try varint()
        let raw = UInt8(key & 0x7)
        guard let wire = WireType(rawValue: raw) else {
            throw ProtobufError.unsupportedWireType(raw)
        }
        return (Int(key >> 3), wire)
    }

    /// Reads a base-128 varint, low group first, high bit meaning "another byte follows".
    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < end {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            // Ten groups of seven bits is the most a 64-bit value can occupy; an eleventh means the
            // stream is not what it claims to be, and continuing would spin to the end of the buffer.
            if shift > 63 { throw ProtobufError.malformedVarint }
        }
        throw ProtobufError.truncated
    }

    /// Reads a length-delimited field as a reader bounded to its bytes.
    mutating func message() throws -> ProtobufReader {
        let length = Int(try varint())
        guard length >= 0, index + length <= end else { throw ProtobufError.truncated }
        let sub = ProtobufReader(bytes: bytes, from: index, to: index + length)
        index += length
        return sub
    }

    /// Reads a length-delimited field as UTF-8 text.
    ///
    /// Invalid UTF-8 is replaced rather than thrown, because a single bad layer name or attribute
    /// value is not a reason to discard a tile of geometry.
    mutating func string() throws -> String {
        let length = Int(try varint())
        guard length >= 0, index + length <= end else { throw ProtobufError.truncated }
        defer { index += length }
        return String(decoding: bytes[index..<(index + length)], as: UTF8.self)
    }

    /// Reads a `double`.
    mutating func double() throws -> Double {
        Double(bitPattern: try fixed64())
    }

    /// Reads a `float`.
    mutating func float() throws -> Float {
        Float(bitPattern: try fixed32())
    }

    mutating func fixed32() throws -> UInt32 {
        guard index + 4 <= end else { throw ProtobufError.truncated }
        defer { index += 4 }
        return UInt32(bytes[index])
            | UInt32(bytes[index + 1]) << 8
            | UInt32(bytes[index + 2]) << 16
            | UInt32(bytes[index + 3]) << 24
    }

    mutating func fixed64() throws -> UInt64 {
        guard index + 8 <= end else { throw ProtobufError.truncated }
        var value: UInt64 = 0
        for offset in 0..<8 {
            value |= UInt64(bytes[index + offset]) << (8 * UInt64(offset))
        }
        index += 8
        return value
    }

    /// Appends a repeated scalar field's values, whichever way the encoder wrote it.
    ///
    /// `packed = true` is the default for repeated scalars in proto3 and what every vector tile
    /// encoder emits — the whole run arrives as one length-delimited blob. The unpacked form, one
    /// key per value, is still legal, and a decoder that assumes packed silently reads a single
    /// value as a field number. Both are cheap to accept.
    mutating func repeatedVarint(into values: inout [UInt32], wire: WireType) throws {
        switch wire {
        case .lengthDelimited:
            var packed = try message()
            while packed.hasMore {
                values.append(UInt32(truncatingIfNeeded: try packed.varint()))
            }
        case .varint:
            values.append(UInt32(truncatingIfNeeded: try varint()))
        default:
            try skip(wire)
        }
    }

    /// Steps over a field whose value this reader does not need.
    ///
    /// This is what lets the decoder read one layer out of a tile carrying twenty, and what keeps
    /// it working when a source adds fields the schema did not have.
    mutating func skip(_ wire: WireType) throws {
        switch wire {
        case .varint:
            _ = try varint()
        case .fixed64:
            guard index + 8 <= end else { throw ProtobufError.truncated }
            index += 8
        case .fixed32:
            guard index + 4 <= end else { throw ProtobufError.truncated }
            index += 4
        case .lengthDelimited:
            let length = Int(try varint())
            guard length >= 0, index + length <= end else { throw ProtobufError.truncated }
            index += length
        }
    }

    /// Undoes zigzag encoding, which protobuf uses for `sint32`/`sint64` and vector tiles use for
    /// every geometry parameter.
    ///
    /// Plain varints are cheap for small positive numbers and ruinous for negative ones, since a
    /// two's-complement -1 sets all 64 bits and costs ten bytes. Zigzag interleaves the signs —
    /// 0, -1, 1, -2 become 0, 1, 2, 3 — so a small negative delta costs one byte like a small
    /// positive one. Vector tile geometry is nothing but small deltas in both directions.
    static func zigzag(_ value: UInt32) -> Int32 {
        Int32(bitPattern: value >> 1) ^ -Int32(bitPattern: value & 1)
    }
}
