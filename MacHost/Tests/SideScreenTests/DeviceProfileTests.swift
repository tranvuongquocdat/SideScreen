import Foundation
import Network
import XCTest
@testable import SideScreen

final class DeviceProfileStoreTests: XCTestCase {
    private func freshStore() -> DeviceProfileStore {
        let suite = "DeviceProfileStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return DeviceProfileStore(defaults: defaults)
    }

    private func settings(resolution: String = "1920x1200", x: Int? = nil) -> ProfileSettings {
        ProfileSettings(
            resolution: resolution, refreshRate: 60, hiDPI: false, rotation: 0,
            flipHorizontal: false, flipVertical: false, bitrate: 1000, quality: "ultralow",
            gamingBoost: false, touchEnabled: true, positionX: x, positionY: x.map { _ in 0 }
        )
    }

    private func profile(_ id: String, at seconds: TimeInterval, _ settings: ProfileSettings? = nil) -> DeviceProfile {
        DeviceProfile(id: id, name: id, lastConnected: Date(timeIntervalSince1970: seconds), settings: settings ?? self.settings())
    }

    func testSaveAndLookUp() {
        let store = freshStore()
        store.save(profile("a", at: 1000, settings(resolution: "2560x1600", x: 1440)))
        XCTAssertEqual(store.profile(id: "a")?.settings.resolution, "2560x1600")
        XCTAssertEqual(store.profile(id: "a")?.settings.positionX, 1440)
        XCTAssertNil(store.profile(id: "b"))
    }

    func testMostRecentIsTheLastConnected() {
        let store = freshStore()
        store.save(profile("old", at: 1000))
        store.save(profile("new", at: 9000))
        store.save(profile("mid", at: 5000))
        XCTAssertEqual(store.mostRecent()?.id, "new")
        XCTAssertEqual(store.all().map(\.id), ["new", "mid", "old"])
    }

    func testOnlyTheMostRecentProfilesAreKept() {
        let store = freshStore()
        let cap = DeviceProfileStore.capacity
        XCTAssertEqual(cap, 20)
        for i in 1...cap { store.save(profile("t\(i)", at: TimeInterval(i * 1000))) }
        XCTAssertEqual(store.all().count, cap)

        store.save(profile("extra", at: TimeInterval((cap + 1) * 1000)))
        XCTAssertEqual(store.all().count, cap)
        XCTAssertNil(store.profile(id: "t1"), "the least recently connected profile is dropped for good")
        XCTAssertNotNil(store.profile(id: "extra"))
    }

    func testReconnectingMovesAProfileToTheFrontWithoutDuplicating() {
        let store = freshStore()
        let cap = DeviceProfileStore.capacity
        for i in 1...cap { store.save(profile("t\(i)", at: TimeInterval(i * 1000))) }
        store.save(profile("t1", at: 90_000))
        XCTAssertEqual(store.all().count, cap)
        XCTAssertEqual(store.mostRecent()?.id, "t1")

        store.save(profile("extra", at: 95_000))
        XCTAssertNil(store.profile(id: "t2"), "t1 was used again, so t2 is now the oldest")
        XCTAssertNotNil(store.profile(id: "t1"))
    }

    func testUpdateSettingsKeepsRecencyAndIgnoresUnknownIds() {
        let store = freshStore()
        store.save(profile("a", at: 1000))
        store.save(profile("b", at: 2000))
        store.updateSettings(settings(resolution: "1280x800"), for: "a")
        XCTAssertEqual(store.profile(id: "a")?.settings.resolution, "1280x800")
        XCTAssertEqual(store.mostRecent()?.id, "b")

        store.updateSettings(settings(resolution: "1280x800"), for: "nope")
        XCTAssertEqual(store.all().count, 2)
    }

    func testForgetAndClear() {
        let store = freshStore()
        store.save(profile("a", at: 1000))
        store.save(profile("b", at: 2000))
        store.forget(id: "a")
        XCTAssertEqual(store.all().map(\.id), ["b"])
        store.clear()
        XCTAssertTrue(store.all().isEmpty)
    }

    func testFallbackKey() {
        XCTAssertEqual(DeviceProfileStore.fallbackKey(deviceName: "Pixel Tablet"), "name:Pixel Tablet")
        XCTAssertNil(DeviceProfileStore.fallbackKey(deviceName: nil))
        XCTAssertNil(DeviceProfileStore.fallbackKey(deviceName: ""))
    }

    func testDisplayShapeIgnoresLiveSettingsAndPosition() {
        var a = settings(x: 0)
        var b = a
        b.bitrate = 200
        b.quality = "high"
        b.flipHorizontal = true
        b.touchEnabled = false
        b.positionX = 2560
        XCTAssertEqual(a.displayShape, b.displayShape)

        b.gamingBoost = true
        XCTAssertNotEqual(a.displayShape, b.displayShape, "Gaming Boost changes the capture rate")
        a.hiDPI = true
        XCTAssertNotEqual(a.displayShape, settings(x: 0).displayShape)
    }
}

/// The server holds a tablet's stream until the host has applied its profile.
final class StreamingServerProfileHoldTests: XCTestCase {
    private let identity = DeviceIdentity(id: "0f8fad5b-d9cb-469f-a165-70867728950e", name: "Tab S9")

    private func connect(to server: StreamingServer) async throws -> NWConnection {
        let port = try XCTUnwrap(server.boundPort)
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let ready = expectation(description: "client ready")
        conn.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        conn.start(queue: DispatchQueue(label: "StreamingServerProfileHoldTests.client"))
        await fulfillment(of: [ready], timeout: 2)
        return conn
    }

    /// Records the first byte the server sends.
    private final class FirstByte {
        private let lock = NSLock()
        private var value: UInt8?
        let arrived: XCTestExpectation

        init(from conn: NWConnection, _ test: XCTestCase) {
            arrived = test.expectation(description: "first server byte")
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64) { [self] data, _, _, _ in
                lock.withLock { value = data?.first }
                arrived.fulfill()
            }
        }

        var byte: UInt8? { lock.withLock { value } }
    }

    func testIdentifiedClientIsHeldUntilResumed() async throws {
        let server = StreamingServer(port: 0)
        defer { server.stop() }
        let asked = expectation(description: "prepare asked")
        var seenKey: String?
        var seenName: String?
        server.onPrepareForClient = { key, name in
            seenKey = key
            seenName = name
            asked.fulfill()
            return false
        }
        try await server.start()

        let conn = try await connect(to: server)
        defer { conn.cancel() }
        var hello = Data([18])
        hello.append(try XCTUnwrap(DeviceIdentityCodec.encode(identity)))
        hello.append(8)
        conn.send(content: hello, completion: .contentProcessed { _ in })

        let first = FirstByte(from: conn, self)
        await fulfillment(of: [asked], timeout: 2)
        XCTAssertEqual(seenKey, identity.id)
        XCTAssertEqual(seenName, "Tab S9")

        // The 100 ms legacy grace must not slip the display config past the hold.
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(first.byte, "no display config while the profile is being applied")

        server.resumeProtocolStartup()
        await fulfillment(of: [first.arrived], timeout: 2)
        XCTAssertEqual(first.byte, 1, "display config once resumed")
    }

    func testLegacyUSBClientIsNotHeld() async throws {
        let server = StreamingServer(port: 0)
        defer { server.stop() }
        let asked = expectation(description: "prepare asked")
        var seenKey: String? = "unset"
        server.onPrepareForClient = { key, _ in
            seenKey = key
            asked.fulfill()
            return true
        }
        try await server.start()

        let conn = try await connect(to: server)
        defer { conn.cancel() }
        let first = FirstByte(from: conn, self)
        conn.send(content: Data([8]), completion: .contentProcessed { _ in })

        await fulfillment(of: [asked, first.arrived], timeout: 2)
        XCTAssertNil(seenKey)
        XCTAssertEqual(first.byte, 1)
    }
}
