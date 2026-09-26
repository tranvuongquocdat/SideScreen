import Foundation
import SystemConfiguration

struct USBADBDevice: Equatable, Identifiable {
    let serial: String
    let model: String?
    var state: String = "device"

    var isReady: Bool { state == "device" }
    var connectionHint: String? {
        switch state {
        case "unauthorized": return "Allow USB debugging on \(displayName)."
        case "offline": return "\(displayName) is offline. Reconnect its USB cable."
        default: return nil
        }
    }

    var id: String { serial }
    var displayName: String {
        let name = model?.replacingOccurrences(of: "_", with: " ") ?? "Android device"
        return "\(name) (\(serial))"
    }

    // libusb omits `usb:`. Exclude ADB's emulator, socket and mDNS serial
    // formats instead of requiring the native USB backend's optional marker.
    static func parse(_ output: String) -> [USBADBDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, ["device", "unauthorized", "offline"].contains(fields[1]),
                  !fields[0].hasPrefix("emulator-"), !fields[0].contains(":"),
                  !fields[0].contains("._tcp") else {
                return nil
            }
            let model = fields.dropFirst(2).first(where: { $0.hasPrefix("model:") })
                .map { String($0.dropFirst("model:".count)) }
            return USBADBDevice(serial: fields[0], model: model, state: fields[1])
        }
    }
}

struct USBADBTunnel: Equatable {
    let serial: String
    let port: Int
}

enum USBADBSelection {
    static func serial(
        from devices: [USBADBDevice],
        current: String?,
        preferred: String?
    ) -> String? {
        if devices.count == 1 { return devices[0].serial }
        guard devices.count > 1 else { return nil }
        if let current, devices.contains(where: { $0.serial == current }) { return current }
        if let preferred, devices.contains(where: { $0.serial == preferred }) { return preferred }
        let ready = devices.filter(\.isReady)
        return ready.count == 1 ? ready[0].serial : nil
    }
}

struct ADBCommandResult {
    let exitCode: Int32
    let output: String

    var succeeded: Bool { exitCode == 0 }
    var errorMessage: String {
        let lastLine = output.split(whereSeparator: \.isNewline).last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return lastLine.isEmpty ? "ADB exited with code \(exitCode)." : String(lastLine.prefix(200))
    }
}

enum StatusDetector {
    static func adbInstalled() -> Bool {
        return adbExecutablePath() != nil
    }

    static func wifiReachable() -> Bool {
        guard let reach = SCNetworkReachabilityCreateWithName(nil, "1.1.1.1") else { return false }
        var flags = SCNetworkReachabilityFlags()
        guard SCNetworkReachabilityGetFlags(reach, &flags) else { return false }
        return flags.contains(.reachable) && !flags.contains(.connectionRequired)
    }

    static func usbDevices(adbPath: String? = nil) -> (devices: [USBADBDevice], error: String?) {
        let result = runADB(["devices", "-l"], adbPath: adbPath)
        guard result.succeeded else { return ([], result.errorMessage) }
        return (USBADBDevice.parse(result.output), nil)
    }

    static func adbReverseStatus(port: Int, serial: String, adbPath: String? = nil) -> (configured: Bool, error: String?) {
        let result = runADB(["-s", serial, "reverse", "--list"], adbPath: adbPath)
        guard result.succeeded else {
            return (false, result.errorMessage)
        }
        let configured = result.output.split(whereSeparator: \.isNewline).contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.suffix(2).map(String.init) == ["tcp:\(port)", "tcp:\(port)"]
        }
        return (configured, nil)
    }

    static func configureADBReverse(port: Int, serial: String, adbPath: String? = nil) -> ADBCommandResult {
        runADB(["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"], adbPath: adbPath)
    }

    static func removeADBReverse(port: Int, serial: String, adbPath: String? = nil) -> (removed: Bool, error: String?) {
        // Do not remove a mapping that another tool has changed to a different port.
        let status = adbReverseStatus(port: port, serial: serial, adbPath: adbPath)
        if let error = status.error { return (false, error) }
        guard status.configured else { return (false, nil) }
        let result = runADB(["-s", serial, "reverse", "--remove", "tcp:\(port)"], adbPath: adbPath)
        return (result.succeeded, result.succeeded ? nil : result.errorMessage)
    }

    private static func runADB(_ arguments: [String], adbPath: String? = nil) -> ADBCommandResult {
        guard let adbPath = adbPath ?? adbExecutablePath() else {
            return ADBCommandResult(exitCode: -1, output: "ADB not found.")
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adbPath)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
        } catch {
            return ADBCommandResult(exitCode: -1, output: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return ADBCommandResult(exitCode: task.terminationStatus, output: output)
    }

    private static let adbPathLock = NSLock()
    private static var cachedAdbPath: String?
    private static var lastAdbCacheCheck: Date = .distantPast

    private static func adbExecutablePath() -> String? {
        adbPathLock.lock()
        defer { adbPathLock.unlock() }
        // Re-resolve every 5 s so install/uninstall is reflected.
        if let cached = cachedAdbPath, Date().timeIntervalSince(lastAdbCacheCheck) < 5.0 {
            return cached
        }
        let candidatePaths = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb"
        ]
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            cachedAdbPath = path
            lastAdbCacheCheck = Date()
            return path
        }
        // Fallback: ask `which adb` (covers PATH-installed setups).
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["adb"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !out.isEmpty,
               FileManager.default.isExecutableFile(atPath: out) {
                cachedAdbPath = out
                lastAdbCacheCheck = Date()
                return out
            }
        } catch {
            // ignore
        }
        cachedAdbPath = nil
        lastAdbCacheCheck = Date()
        return nil
    }
}
