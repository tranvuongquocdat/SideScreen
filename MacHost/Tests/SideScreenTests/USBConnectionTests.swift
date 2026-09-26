import Foundation
import XCTest
@testable import SideScreen

final class USBConnectionTests: XCTestCase {
    private class RecordingServer: StreamingServer {
        let events: URL

        init(events: URL) {
            self.events = events
            super.init(port: 0)
        }

        override func disconnectClient() async {
            do {
                let handle = try FileHandle(forWritingTo: events)
                handle.seekToEndOfFile()
                handle.write(Data("disconnect client\n".utf8))
                try handle.close()
            } catch {
                XCTFail("Could not record client disconnect: \(error)")
            }
        }
    }

    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let script = """
        #!/bin/sh
        fixture_dir="${0%/*}"
        printf '%s\\n' "$*" >> "$fixture_dir/events"
        if [ "$*" = 'devices -l' ]; then cat "$fixture_dir/devices"; exit 0; fi
        if [ "$1" != '-s' ] || [ "$3" != 'reverse' ]; then exit 1; fi
        case "$4" in
          --list)
            touch "$fixture_dir/list-started"
            while [ -e "$fixture_dir/hold-list" ]; do sleep 0.01; done
            cat "$fixture_dir/$2" 2>/dev/null; exit 0 ;;
          --remove)
            if [ -e "$fixture_dir/fail-remove" ]; then echo 'error: removal failed' >&2; exit 1; fi
            : > "$fixture_dir/$2" ;;
          tcp:*)
            touch "$fixture_dir/setup-started"
            while [ -e "$fixture_dir/hold-setup" ]; do sleep 0.01; done
            if [ -e "$fixture_dir/fail-setup" ]; then echo 'error: setup failed' >&2; exit 1; fi
            printf '%s %s %s\\n' "$2" "$4" "$5" > "$fixture_dir/$2" ;;
          *) exit 1 ;;
        esac
        """
        try script.write(to: directory.appendingPathComponent("adb"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.appendingPathComponent("adb").path)
        try "A device model:Tablet_A\nB device usb:2-2 model:Tablet_B\n".write(
            to: directory.appendingPathComponent("devices"), atomically: true, encoding: .utf8)
        return directory
    }

    @MainActor
    private func delegate(in directory: URL) -> AppDelegate {
        let app = AppDelegate()
        app.settings.connectionMode = .usb
        app.settings.port = 54321
        app.settings.selectedUSBSerial = "A"
        app.settings.isRunning = true
        app.streamingServer = RecordingServer(events: directory.appendingPathComponent("events"))
        return app
    }

    @MainActor
    func testInitialSelectionRetiresInheritedTunnelAndPreservesUnrelatedMapping() async throws {
        let directory = try fixture()
        try "A device\nB device\nC device\n".write(
            to: directory.appendingPathComponent("devices"), atomically: true, encoding: .utf8)
        try "A tcp:54321 tcp:54321\n".write(to: directory.appendingPathComponent("A"), atomically: true, encoding: .utf8)
        try "C tcp:54321 tcp:12345\n".write(to: directory.appendingPathComponent("C"), atomically: true, encoding: .utf8)
        let app = delegate(in: directory)
        app.settings.selectedUSBSerial = "B"
        let path = directory.appendingPathComponent("adb").path
        await app.refreshUSBStatus(adbPath: path)

        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("A")), "")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("B")), "B tcp:54321 tcp:54321\n")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("C")), "C tcp:54321 tcp:12345\n")
        XCTAssertTrue(app.settings.adbReverseConfigured)
        let events = try String(contentsOf: directory.appendingPathComponent("events"))
        let removal = try XCTUnwrap(events.range(of: "-s A reverse --remove tcp:54321"))
        let disconnect = try XCTUnwrap(events.range(of: "disconnect client"))
        let setup = try XCTUnwrap(events.range(of: "-s B reverse tcp:54321 tcp:54321"))
        XCTAssertLessThan(removal.lowerBound, disconnect.lowerBound)
        XCTAssertLessThan(disconnect.lowerBound, setup.lowerBound)

        try "".write(to: directory.appendingPathComponent("events"), atomically: true, encoding: .utf8)
        await app.refreshUSBStatus(adbPath: path)
        XCTAssertFalse(try String(contentsOf: directory.appendingPathComponent("events")).contains("disconnect client"))
        XCTAssertTrue(app.settings.adbReverseConfigured)
    }

    @MainActor
    func testPendingSelectionRetiresAllInheritedTunnelsWithoutConfiguringOne() async throws {
        let directory = try fixture()
        for serial in ["A", "B"] {
            try "\(serial) tcp:54321 tcp:54321\n".write(
                to: directory.appendingPathComponent(serial), atomically: true, encoding: .utf8)
        }
        let app = delegate(in: directory)
        app.settings.selectedUSBSerial = nil
        app.settings.isRunning = false
        await app.refreshUSBStatus(adbPath: directory.appendingPathComponent("adb").path)

        XCTAssertNil(app.settings.selectedUSBSerial)
        XCTAssertFalse(app.settings.adbReverseConfigured)
        for serial in ["A", "B"] {
            XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(serial)), "")
        }
        let events = try String(contentsOf: directory.appendingPathComponent("events"))
        XCTAssertTrue(events.contains("disconnect client"))
        XCTAssertFalse(events.contains("reverse tcp:"))
    }

    @MainActor
    func testInheritedTunnelRemovalFailureBlocksSetupAndRecovers() async throws {
        let directory = try fixture()
        try "A tcp:54321 tcp:54321\n".write(to: directory.appendingPathComponent("A"), atomically: true, encoding: .utf8)
        try Data().write(to: directory.appendingPathComponent("fail-remove"))
        let app = delegate(in: directory)
        app.settings.selectedUSBSerial = "B"
        let path = directory.appendingPathComponent("adb").path
        await app.refreshUSBStatus(adbPath: path)

        XCTAssertEqual(app.settings.adbError, "ADB disconnect previous tablet: error: removal failed")
        XCTAssertFalse(app.settings.adbReverseConfigured)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("B").path))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("fail-remove"))
        await app.refreshUSBStatus(adbPath: path)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("A")), "")
        XCTAssertTrue(app.settings.adbReverseConfigured)
        XCTAssertNil(app.settings.adbError)
    }

    @MainActor
    func testSwitchRemovesOnlyPreviousTunnelAndDisconnectsBeforeConfiguringNext() async throws {
        let directory = try fixture()
        let app = delegate(in: directory)
        let path = directory.appendingPathComponent("adb").path
        await app.refreshUSBStatus(adbPath: path)
        XCTAssertTrue(app.settings.adbReverseConfigured)

        app.settings.selectedUSBSerial = "B"
        await app.refreshUSBStatus(adbPath: path)
        let events = try String(contentsOf: directory.appendingPathComponent("events"))
        let removal = try XCTUnwrap(events.range(of: "-s A reverse --remove tcp:54321"))
        let disconnect = try XCTUnwrap(events.range(of: "disconnect client"))
        let setup = try XCTUnwrap(events.range(of: "-s B reverse tcp:54321 tcp:54321"))
        XCTAssertLessThan(removal.lowerBound, disconnect.lowerBound)
        XCTAssertLessThan(disconnect.lowerBound, setup.lowerBound)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("A")), "")
        XCTAssertTrue(app.settings.adbReverseConfigured)
        XCTAssertNil(app.settings.adbError)
        XCTAssertFalse(events.contains("--remove-all"))
    }

    @MainActor
    func testFailedRemovalBlocksSwitchAndRecoversOnNextRefresh() async throws {
        let directory = try fixture()
        let app = delegate(in: directory)
        let path = directory.appendingPathComponent("adb").path
        await app.refreshUSBStatus(adbPath: path)
        try Data().write(to: directory.appendingPathComponent("fail-remove"))
        app.settings.selectedUSBSerial = "B"
        await app.refreshUSBStatus(adbPath: path)
        XCTAssertEqual(app.settings.adbError, "ADB disconnect previous tablet: error: removal failed")
        XCTAssertFalse(app.settings.adbReverseConfigured)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("B").path))

        try FileManager.default.removeItem(at: directory.appendingPathComponent("fail-remove"))
        await app.refreshUSBStatus(adbPath: path)
        XCTAssertTrue(app.settings.adbReverseConfigured)
        XCTAssertNil(app.settings.adbError)
    }

    @MainActor
    func testDeviceStatesAndSetupErrorsRecoverWithoutLosingSelection() async throws {
        let directory = try fixture()
        let app = delegate(in: directory)
        let path = directory.appendingPathComponent("adb").path
        for state in ["unauthorized", "offline"] {
            try "A \(state) transport_id:1\n".write(to: directory.appendingPathComponent("devices"), atomically: true, encoding: .utf8)
            await app.refreshUSBStatus(adbPath: path)
            XCTAssertEqual(app.settings.selectedUSBSerial, "A")
            XCTAssertNotNil(app.settings.usbDeviceNotice)
            XCTAssertFalse(app.settings.adbReverseConfigured)
            XCTAssertFalse(try String(contentsOf: directory.appendingPathComponent("events")).contains(" reverse "))
        }
        try "A device model:Tablet_A\n".write(to: directory.appendingPathComponent("devices"), atomically: true, encoding: .utf8)
        try Data().write(to: directory.appendingPathComponent("fail-setup"))
        await app.refreshUSBStatus(adbPath: path)
        XCTAssertEqual(app.settings.adbError, "ADB reverse: error: setup failed")
        XCTAssertNil(app.settings.usbDeviceNotice)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("fail-setup"))
        await app.refreshUSBStatus(adbPath: path)
        XCTAssertTrue(app.settings.adbReverseConfigured)
        XCTAssertNil(app.settings.adbError)
    }

    @MainActor
    func testUnpluggedPreviousDeviceDoesNotBlockSwitch() async throws {
        let directory = try fixture()
        let app = delegate(in: directory)
        let path = directory.appendingPathComponent("adb").path
        await app.refreshUSBStatus(adbPath: path)
        try "B device model:Tablet_B\n".write(to: directory.appendingPathComponent("devices"), atomically: true, encoding: .utf8)
        await app.refreshUSBStatus(adbPath: path)
        XCTAssertEqual(app.settings.selectedUSBSerial, "B")
        XCTAssertTrue(app.settings.adbReverseConfigured)
        let events = try String(contentsOf: directory.appendingPathComponent("events"))
        XCTAssertTrue(events.contains("disconnect client"))
        XCTAssertFalse(events.contains("--remove"))
    }

    @MainActor
    func testSelectionChangedDuringSetupRetiresStaleTunnelOnNextRefresh() async throws {
        try await checkSelectionChangedDuringOperation("setup")
    }

    @MainActor
    func testSelectionChangedDuringCheckRetiresExistingTunnelOnNextRefresh() async throws {
        try await checkSelectionChangedDuringOperation("list")
    }

    @MainActor
    private func checkSelectionChangedDuringOperation(_ operation: String) async throws {
        let directory = try fixture()
        let app = delegate(in: directory)
        let path = directory.appendingPathComponent("adb").path
        if operation == "list" {
            try "A tcp:54321 tcp:54321\n".write(to: directory.appendingPathComponent("A"), atomically: true, encoding: .utf8)
        }
        let started = directory.appendingPathComponent("\(operation)-started")
        let hold = directory.appendingPathComponent("hold-\(operation)")
        try Data().write(to: hold)
        defer { try? FileManager.default.removeItem(at: hold) }
        let first = Task { await app.refreshUSBStatus(adbPath: path) }
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: started.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        app.settings.selectedUSBSerial = "B"
        await app.refreshUSBStatus(adbPath: path)
        try FileManager.default.removeItem(at: hold)
        await first.value
        await app.refreshUSBStatus(adbPath: path)
        XCTAssertTrue(app.settings.adbReverseConfigured)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("A")), "")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("B")), "B tcp:54321 tcp:54321\n")
    }

    func testCleanupPreservesMappingToAnotherPort() throws {
        let directory = try fixture()
        try "A tcp:54321 tcp:12345\n".write(to: directory.appendingPathComponent("A"), atomically: true, encoding: .utf8)
        let result = StatusDetector.removeADBReverse(port: 54321, serial: "A", adbPath: directory.appendingPathComponent("adb").path)
        XCTAssertNil(result.error)
        XCTAssertFalse(result.removed)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("A")), "A tcp:54321 tcp:12345\n")
    }
}
