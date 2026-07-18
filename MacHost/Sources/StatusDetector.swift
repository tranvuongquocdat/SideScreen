import Darwin
import Foundation
import SystemConfiguration

enum StatusDetector {
    enum ADBStatus: Equatable, Sendable {
        case checking
        case missing
        case noDevice
        case unauthorized
        case offline
        case multipleDevices
        case ready
        case reverseMissing
        case commandError(exitCode: Int32?, message: String)
    }

    /// Probe the complete USB/ADB path. `CommandResult.output` contains both
    /// stdout and stderr, so non-zero exits can be classified by diagnostics.
    static func adbStatus(port: Int) -> ADBStatus {
        guard adbExecutablePath() != nil else {
            return .missing
        }

        guard let devicesResult = runADB(arguments: ["devices"]) else {
            return .commandError(
                exitCode: nil,
                message: "`adb devices` timed out or could not be started."
            )
        }
        guard devicesResult.terminationStatus == 0 else {
            return classifyADBFailure(devicesResult, command: "adb devices")
        }

        let deviceStates = devicesResult.output
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.contains("\t") else { return nil }
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard fields.count >= 2 else { return nil }
                return String(fields[1]).lowercased()
            }

        if deviceStates.count > 1 {
            return .multipleDevices
        }
        guard let deviceState = deviceStates.first else {
            return .noDevice
        }

        switch deviceState {
        case "unauthorized":
            return .unauthorized
        case "offline":
            return .offline
        case "device":
            break
        default:
            return .commandError(
                exitCode: 0,
                message: "Unexpected ADB device state: \(deviceState)"
            )
        }

        guard let reverseResult = runADB(arguments: ["reverse", "--list"]) else {
            return .commandError(
                exitCode: nil,
                message: "`adb reverse --list` timed out or could not be started."
            )
        }
        guard reverseResult.terminationStatus == 0 else {
            return classifyADBFailure(reverseResult, command: "adb reverse --list")
        }

        let mapping = "tcp:\(port) tcp:\(port)"
        return reverseResult.output.contains(mapping) ? .ready : .reverseMissing
    }

    private static func classifyADBFailure(
        _ result: CommandResult,
        command: String
    ) -> ADBStatus {
        let normalized = result.output.lowercased()
        if normalized.contains("more than one device") || normalized.contains("multiple devices") {
            return .multipleDevices
        }
        if normalized.contains("unauthorized") || normalized.contains("no permissions") {
            return .unauthorized
        }
        if normalized.contains("offline") {
            return .offline
        }
        if normalized.contains("no devices/emulators found") || normalized.contains("device not found") {
            return .noDevice
        }

        let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .commandError(
            exitCode: result.terminationStatus,
            message: detail.isEmpty ? "`\(command)` failed." : detail
        )
    }

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
