import Foundation
import XCTest
@testable import SideScreen

final class USBADBDeviceTests: XCTestCase {
    private let mixedDevices = """
    List of devices attached
    TABLET_A               device usb:2-2 product:tablet_a model:Test_Tablet device:tablet_a transport_id:17
    emulator-5580          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:26
    192.0.2.12:5555        device product:tablet model:Wireless_Tablet device:tablet transport_id:28
    OTHER                  unauthorized usb:2-3 transport_id:29
    """

    func testPhysicalDevicesAreListedButOnlyReadyDeviceIsAutomaticallySelected() {
        let devices = USBADBDevice.parse(mixedDevices)
        XCTAssertEqual(devices, [
            USBADBDevice(serial: "TABLET_A", model: "Test_Tablet"),
            USBADBDevice(serial: "OTHER", model: nil, state: "unauthorized")
        ])
        XCTAssertEqual(
            USBADBSelection.serial(from: devices, current: nil, preferred: nil),
            "TABLET_A"
        )
    }

    func testMultiplePhysicalDevicesRequireAChoiceAndReuseItWhilePresent() {
        let output = mixedDevices + "\nTABLET_B device usb:2-4 model:Second_Tablet transport_id:30\n"
        let devices = USBADBDevice.parse(output)
        XCTAssertEqual(devices.count, 3)
        XCTAssertNil(USBADBSelection.serial(from: devices, current: nil, preferred: nil))
        XCTAssertEqual(
            USBADBSelection.serial(from: devices, current: nil, preferred: "TABLET_B"),
            "TABLET_B"
        )
        XCTAssertEqual(
            USBADBSelection.serial(from: devices, current: "TABLET_A", preferred: "TABLET_B"),
            "TABLET_A"
        )
        XCTAssertEqual(
            USBADBSelection.serial(from: [devices[2]], current: "TABLET_A", preferred: nil),
            "TABLET_B"
        )
        XCTAssertNil(USBADBSelection.serial(from: [], current: "TABLET_B", preferred: "TABLET_B"))
    }

    func testLibusbOutputKeepsUSBDevicesAndExcludesNetworkTransports() {
        let output = """
        * daemon started successfully *
        List of devices attached
        USB123 device product:tablet model:Test_Tablet transport_id:1
        emulator-5554 device model:Emulator transport_id:2
        192.0.2.12:5555 device model:WiFi transport_id:3
        [2001:db8::1]:5555 device model:WiFi transport_id:4
        tablet.local:5555 device model:WiFi transport_id:5
        adb-USB123-example._adb-tls-connect._tcp device model:WiFi transport_id:6
        """
        XCTAssertEqual(USBADBDevice.parse(output), [USBADBDevice(serial: "USB123", model: "Test_Tablet")])
    }

    func testUnavailableDevicesRetainActionableStates() {
        let devices = USBADBDevice.parse("A unauthorized transport_id:1\nB offline usb:2-3 transport_id:2")
        XCTAssertEqual(devices.map(\.state), ["unauthorized", "offline"])
        XCTAssertTrue(devices.allSatisfy { !$0.isReady })
        XCTAssertEqual(devices[0].connectionHint, "Allow USB debugging on Android device (A).")
        XCTAssertEqual(devices[1].connectionHint, "Android device (B) is offline. Reconnect its USB cable.")
        XCTAssertEqual(USBADBSelection.serial(from: devices, current: "B", preferred: nil), "B")
    }

    func testADBCommandsTargetOnlyTheChosenSerial() throws {
        let script = """
        #!/bin/sh
        case "$*" in
          "devices -l")
            printf '%s\n' 'List of devices attached' 'USB123 device usb:2-1 model:Test_Tablet transport_id:1' 'emulator-5554 device model:Emulator transport_id:2'
            ;;
          "-s USB123 reverse --list")
            printf '%s\n' 'USB123 tcp:54321 tcp:54321'
            ;;
          "-s USB123 reverse tcp:54321 tcp:54321")
            exit 0
            ;;
          "-s USB123 reverse tcp:54322 tcp:54322")
            printf '%s\n' 'error: device offline' >&2
            exit 1
            ;;
          *) printf '%s\n' 'error: device not found' >&2; exit 1 ;;
        esac
        """
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidescreen-test-adb-\(UUID().uuidString)")
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        defer { try? FileManager.default.removeItem(at: path) }

        XCTAssertEqual(StatusDetector.usbDevices(adbPath: path.path).devices.map(\.serial), ["USB123"])
        XCTAssertTrue(StatusDetector.adbReverseStatus(port: 54321, serial: "USB123", adbPath: path.path).configured)
        XCTAssertEqual(StatusDetector.adbReverseStatus(port: 54321, serial: "emulator-5554", adbPath: path.path).error,
                       "error: device not found")
        XCTAssertTrue(StatusDetector.configureADBReverse(port: 54321, serial: "USB123", adbPath: path.path).succeeded)
        XCTAssertEqual(StatusDetector.configureADBReverse(port: 54322, serial: "USB123", adbPath: path.path).errorMessage,
                       "error: device offline")
    }

    func testADBDeviceListingFailureReturnsItsError() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidescreen-test-adb-\(UUID().uuidString)")
        try "#!/bin/sh\nprintf '%s\\n' 'error: cannot connect to daemon' >&2\nexit 1\n"
            .write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        defer { try? FileManager.default.removeItem(at: path) }

        let result = StatusDetector.usbDevices(adbPath: path.path)
        XCTAssertTrue(result.devices.isEmpty)
        XCTAssertEqual(result.error, "error: cannot connect to daemon")
    }
}
