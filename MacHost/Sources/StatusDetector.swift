import Foundation
import SystemConfiguration

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

    /// Run `adb devices`, return list of device serials in `device` state.
    static func usbDevices() -> [String] {
        guard let adbPath = adbExecutablePath() else { return [] }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adbPath)
        task.arguments = ["devices"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let serials: [String] = output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count == 2, parts[1] == "device" else { return nil }
            return parts[0]
        }
        // A replugged legacy device lost its reverse: forget it once it is gone.
        legacyLock.lock()
        reversedLegacySerials.formIntersection(serials)
        legacyLock.unlock()
        return serials
    }

    // Android 5.x adbd crashes on `adb reverse --list` once a reverse exists, which
    // drops the device and the stream every refresh tick. For those devices remember
    // the reverses this app set instead of asking adbd.
    private static let legacyLock = NSLock()
    private static var legacyBySerial: [String: Bool] = [:]
    private static var reversedLegacySerials = Set<String>()

    static func isLegacyAdbd(serial: String) -> Bool {
        legacyLock.lock()
        if let known = legacyBySerial[serial] {
            legacyLock.unlock()
            return known
        }
        legacyLock.unlock()
        guard let adbPath = adbExecutablePath() else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adbPath)
        task.arguments = ["-s", serial, "shell", "getprop", "ro.build.version.sdk"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return false
        }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let sdk = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        let legacy = sdk < 23
        legacyLock.lock()
        legacyBySerial[serial] = legacy
        legacyLock.unlock()
        return legacy
    }

    static func markReversed(serial: String) {
        legacyLock.lock()
        reversedLegacySerials.insert(serial)
        legacyLock.unlock()
    }

    /// Heuristic: parse `adb reverse --list` for `tcp:<port> tcp:<port>`.
    /// `serial` targets one device; without it adb refuses as soon as two
    /// devices are attached ("more than one device").
    static func adbReverseConfigured(port: Int, serial: String? = nil) -> Bool {
        if let serial, isLegacyAdbd(serial: serial) {
            legacyLock.lock()
            defer { legacyLock.unlock() }
            return reversedLegacySerials.contains(serial)
        }
        guard let adbPath = adbExecutablePath() else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adbPath)
        task.arguments = (serial.map { ["-s", $0] } ?? []) + ["reverse", "--list"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.contains("tcp:\(port) tcp:\(port)")
    }

    private static var cachedAdbPath: String?
    private static var lastAdbCacheCheck: Date = .distantPast

    static func adbExecutablePath() -> String? {
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
