import Darwin
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
        guard let result = runADB(arguments: ["devices"]),
              result.terminationStatus == 0 else { return [] }
        return result.output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count == 2, parts[1] == "device" else { return nil }
            return parts[0]
        }
    }

    /// Heuristic: parse `adb reverse --list` for `tcp:<port> tcp:<port>`.
    static func adbReverseConfigured(port: Int) -> Bool {
        guard let result = runADB(arguments: ["reverse", "--list"]),
              result.terminationStatus == 0 else { return false }
        return result.output.contains("tcp:\(port) tcp:\(port)")
    }

    struct CommandResult {
        let terminationStatus: Int32
        let output: String
    }

    private final class CommandOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    static func runADB(arguments: [String], timeout: TimeInterval = 2.5) -> CommandResult? {
        guard let adbPath = adbExecutablePath() else { return nil }
        return runProcess(executablePath: adbPath, arguments: arguments, timeout: timeout)
    }

    private static func runProcess(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> CommandResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let outputBuffer = CommandOutputBuffer()
        let outputFinished = DispatchSemaphore(value: 0)
        let outputHandle = pipe.fileHandleForReading
        outputHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                outputFinished.signal()
            } else {
                outputBuffer.append(chunk)
            }
        }

        let processFinished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            processFinished.signal()
        }

        do {
            try process.run()
        } catch {
            outputHandle.readabilityHandler = nil
            return nil
        }

        if processFinished.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning {
                process.terminate()
            }
            if processFinished.wait(timeout: .now() + 0.25) == .timedOut,
               process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = processFinished.wait(timeout: .now() + 0.25)
            }
            outputHandle.readabilityHandler = nil
            return nil
        }

        guard outputFinished.wait(timeout: .now() + 0.5) == .success else {
            outputHandle.readabilityHandler = nil
            return nil
        }
        outputHandle.readabilityHandler = nil

        let output = String(data: outputBuffer.snapshot(), encoding: .utf8) ?? ""
        return CommandResult(terminationStatus: process.terminationStatus, output: output)
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
        if let result = runProcess(
            executablePath: "/usr/bin/which",
            arguments: ["adb"],
            timeout: 2.5
        ), result.terminationStatus == 0 {
            let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if NSString(string: path).isAbsolutePath,
               FileManager.default.isExecutableFile(atPath: path) {
                cachedAdbPath = path
                lastAdbCacheCheck = Date()
                return path
            }
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
