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
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count == 2, parts[1] == "device" else { return nil }
            return parts[0]
        }
    }

    /// Heuristic: parse `adb reverse --list` for `tcp:<port> tcp:<port>`.
    static func adbReverseConfigured(port: Int) -> Bool {
        guard let adbPath = adbExecutablePath() else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adbPath)
        task.arguments = ["reverse", "--list"]
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
    private static let adbPathLock = NSLock()

    static func adbExecutablePath() -> String? {
        adbPathLock.lock()
        defer { adbPathLock.unlock() }

        // Re-resolve every 5 s so install/uninstall is reflected.
        let cacheAge = Date().timeIntervalSince(lastAdbCacheCheck)
        if cacheAge < 5.0 {
            if let cached = cachedAdbPath,
               FileManager.default.isExecutableFile(atPath: cached) {
                return cached
            }
            if cachedAdbPath == nil {
                return nil
            }
        }

        // Search PATH first, but only accept an executable absolute path.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["adb"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if task.terminationStatus == 0,
               let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               NSString(string: path).isAbsolutePath,
               FileManager.default.isExecutableFile(atPath: path) {
                cachedAdbPath = path
                lastAdbCacheCheck = Date()
                return path
            }
        } catch {
            // Continue with known absolute paths.
        }

        let candidatePaths = [
            "\(NSHomeDirectory())/.local/bin/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb"
        ]
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            cachedAdbPath = path
            lastAdbCacheCheck = Date()
            return path
        }

        cachedAdbPath = nil
        lastAdbCacheCheck = Date()
        return nil
    }
}
