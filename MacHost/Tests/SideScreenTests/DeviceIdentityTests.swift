import XCTest
@testable import SideScreen

final class DeviceIdentityCodecTests: XCTestCase {
    private let sample = DeviceIdentity(id: "0f8fad5b-d9cb-469f-a165-70867728950e", name: "SM-X710")

    func testRoundTrip() throws {
        let encoded = try XCTUnwrap(DeviceIdentityCodec.encode(sample))
        XCTAssertEqual(DeviceIdentityCodec.decode(encoded), sample)
    }

    func testEveryPayloadByteHasTheHighBitSet() throws {
        let encoded = try XCTUnwrap(DeviceIdentityCodec.encode(sample))
        XCTAssertTrue(encoded.allSatisfy { $0 & 0x80 != 0 })
        XCTAssertEqual(encoded.count, DeviceIdentityCodec.headerLength + 2 * "SM-X710".utf8.count)
    }

    func testIdIsNormalisedToLowerCase() throws {
        let upper = DeviceIdentity(id: "0F8FAD5B-D9CB-469F-A165-70867728950E", name: "x")
        let encoded = try XCTUnwrap(DeviceIdentityCodec.encode(upper))
        XCTAssertEqual(DeviceIdentityCodec.decode(encoded)?.id, "0f8fad5b-d9cb-469f-a165-70867728950e")
    }

    func testNonASCIINameRoundTrips() throws {
        let identity = DeviceIdentity(id: sample.id, name: "Máy tính bảng của Đạt")
        let encoded = try XCTUnwrap(DeviceIdentityCodec.encode(identity))
        XCTAssertEqual(DeviceIdentityCodec.decode(encoded)?.name, identity.name)
    }

    func testEmptyNameIsAllowed() throws {
        let identity = DeviceIdentity(id: sample.id, name: "")
        let encoded = try XCTUnwrap(DeviceIdentityCodec.encode(identity))
        XCTAssertEqual(encoded.count, DeviceIdentityCodec.headerLength)
        XCTAssertEqual(DeviceIdentityCodec.decode(encoded), identity)
    }

    func testOverlongNameIsTruncatedToTheCountByteLimit() throws {
        let identity = DeviceIdentity(id: sample.id, name: String(repeating: "a", count: 300))
        let encoded = try XCTUnwrap(DeviceIdentityCodec.encode(identity))
        XCTAssertEqual(DeviceIdentityCodec.decode(encoded)?.name.utf8.count, DeviceIdentityCodec.maxNameBytes)
    }

    func testInvalidUUIDCannotBeEncoded() {
        XCTAssertNil(DeviceIdentityCodec.encode(DeviceIdentity(id: "not-a-uuid", name: "x")))
    }

    func testPayloadLengthFollowsTheCountByte() {
        XCTAssertEqual(DeviceIdentityCodec.payloadLength(countByte: 0x80), DeviceIdentityCodec.headerLength)
        XCTAssertEqual(DeviceIdentityCodec.payloadLength(countByte: 0x87), DeviceIdentityCodec.headerLength + 14)
        XCTAssertNil(DeviceIdentityCodec.payloadLength(countByte: 0x07))
    }

    func testMalformedPayloadIsRejected() throws {
        var encoded = try XCTUnwrap(DeviceIdentityCodec.encode(sample))
        XCTAssertNil(DeviceIdentityCodec.decode(encoded.dropLast()))
        XCTAssertNil(DeviceIdentityCodec.decode(encoded + Data([0x81])))
        encoded[3] &= 0x7F
        XCTAssertNil(DeviceIdentityCodec.decode(encoded))
    }
}
