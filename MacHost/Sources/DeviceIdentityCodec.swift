import Foundation

/// A tablet's stable identity, sent as wire type 18 right after connect so
/// the host can bring back that device's own settings profile every time.
struct DeviceIdentity: Equatable {
    /// Random UUID the tablet app generated once and keeps in its
    /// preferences (lower-case, 32 hex digits). Survives reconnects and
    /// reboots; changes only when the app is reinstalled.
    let id: String
    /// Human-readable model name (Build.MODEL), for the Settings list.
    let name: String
}

/// Wire type 18 payload: every byte has the high bit set so hosts that
/// predate the type (and skip unknown input one byte at a time) never
/// mistake a payload byte for a message type — the same rule as types 11/14.
///
///     [16 UUID bytes, each as 0x80|hi-nibble 0x80|lo-nibble]   32 bytes
///     [0x80 | name byte count]                                  1 byte
///     [name UTF-8 bytes, nibble-encoded the same way]           2×count
enum DeviceIdentityCodec {
    static let uuidByteCount = 16
    static let encodedUUIDLength = 2 * uuidByteCount
    /// Longest name the single count byte can carry.
    static let maxNameBytes = 0x7F
    /// Payload length before the name is known.
    static let headerLength = encodedUUIDLength + 1

    /// Payload length for a header whose count byte has been read. Nil when
    /// the count byte is malformed (high bit clear).
    static func payloadLength(countByte: UInt8) -> Int? {
        guard countByte & 0x80 != 0 else { return nil }
        return headerLength + 2 * Int(countByte & 0x7F)
    }

    static func encode(_ identity: DeviceIdentity) -> Data? {
        guard let uuid = UUID(uuidString: identity.id) else { return nil }
        var nameBytes = Array(identity.name.utf8)
        while nameBytes.count > maxNameBytes { nameBytes.removeLast() }

        var out = Data(capacity: headerLength + 2 * nameBytes.count)
        withUnsafeBytes(of: uuid.uuid) { raw in
            for byte in raw { appendNibbles(byte, to: &out) }
        }
        out.append(0x80 | UInt8(nameBytes.count))
        for byte in nameBytes { appendNibbles(byte, to: &out) }
        return out
    }

    /// Nil unless `payload` is exactly one well-formed identity.
    static func decode(_ payload: Data) -> DeviceIdentity? {
        guard payload.count >= headerLength,
              payload.allSatisfy({ $0 & 0x80 != 0 }) else { return nil }
        let bytes = Array(payload)
        guard let expected = payloadLength(countByte: bytes[encodedUUIDLength]),
              bytes.count == expected else { return nil }

        var uuidBytes = [UInt8](repeating: 0, count: uuidByteCount)
        for i in 0..<uuidByteCount {
            uuidBytes[i] = joinNibbles(bytes[2 * i], bytes[2 * i + 1])
        }
        let nameCount = Int(bytes[encodedUUIDLength] & 0x7F)
        var nameBytes = [UInt8](repeating: 0, count: nameCount)
        for i in 0..<nameCount {
            let at = headerLength + 2 * i
            nameBytes[i] = joinNibbles(bytes[at], bytes[at + 1])
        }
        let uuid = uuidBytes.withUnsafeBytes { raw -> UUID in
            UUID(uuid: raw.load(as: uuid_t.self))
        }
        // Invalid UTF-8 (a buggy client) still yields a usable identity:
        // the UUID is the key, the name is only a label.
        let name = String(bytes: nameBytes, encoding: .utf8) ?? ""
        return DeviceIdentity(id: uuid.uuidString.lowercased(), name: name)
    }

    private static func appendNibbles(_ byte: UInt8, to out: inout Data) {
        out.append(0x80 | (byte >> 4))
        out.append(0x80 | (byte & 0x0F))
    }

    private static func joinNibbles(_ hi: UInt8, _ lo: UInt8) -> UInt8 {
        ((hi & 0x0F) << 4) | (lo & 0x0F)
    }
}
