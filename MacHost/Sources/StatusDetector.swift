import Foundation
import SystemConfiguration

struct USBADBDevice: Equatable, Identifiable {
    let serial: String
    let model: String?

    var id: String { serial }
    var displayName: String {
        let name = model?.replacingOccurrences(of: "_", with: " ") ?? "Android device"
        return "\(name) (\(serial))"
    }

    /// Only transports marked `usb:` by ADB are physical USB devices. This
    /// excludes both emulators and devices paired over ADB Wi-Fi.
    static func parse(_ output: String) -> [USBADBDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 3, fields[1] == "device",
                  fields.dropFirst(2).contains(where: { $0.hasPrefix("usb:") }) else {
                return nil
            }
            let model = fields.dropFirst(2).first(where: { $0.hasPrefix("model:") })
                .map { String($0.dropFirst("model:".count)) }
            return USBADBDevice(serial: fields[0], model: model)
        }
    }
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
        return nil
    }
}

struct ADBCommandResult {
    let exitCode: Int32
    let output: String

    var succeeded: Bool { exitCode == 0 }
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

    static func usbDevices(adbPath: String? = nil) -> [USBADBDevice] {
        guard let result = runADB(["devices", "-l"], adbPath: adbPath), result.succeeded else { return [] }
        return USBADBDevice.parse(result.output)
    }

    static func adbReverseConfigured(port: Int, serial: String, adbPath: String? = nil) -> Bool {
        guard let result = runADB(["-s", serial, "reverse", "--list"], adbPath: adbPath), result.succeeded else {
            return false
        }
        return result.output.split(whereSeparator: \.isNewline).contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.suffix(2).map(String.init) == ["tcp:\(port)", "tcp:\(port)"]
        }
    }

    static func configureADBReverse(port: Int, serial: String, adbPath: String? = nil) -> ADBCommandResult? {
        runADB(["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"], adbPath: adbPath)
    }

    private static func runADB(_ arguments: [String], adbPath: String? = nil) -> ADBCommandResult? {
        guard let adbPath = adbPath ?? adbExecutablePath() else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adbPath)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
        } catch {
            return nil
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
