import Foundation
import CoreMedia

// Disable stdout buffering so output appears immediately when piped
setbuf(stdout, nil)
setbuf(stderr, nil)

// ============================================
//  StreamTest - Isolate encode→stream→decode
// ============================================
// Tests:
//  1. Generate animated color bar test pattern
//  2. Encode with H.265 (VideoToolbox) - same config as SideScreen
//  3. Save raw bitstream to /tmp/streamtest.h265 (verify with ffplay)
//  4. Stream via TCP to Android tablet (same protocol as SideScreen)
//
// Usage:
//   StreamTest              → encode + save H.265 file (no streaming)
//   StreamTest --stream     → encode + stream to tablet on port 5555
//   StreamTest --stream 6000 → stream on custom port

let args = CommandLine.arguments
let streamMode = args.contains("--stream")
let port: UInt16 = {
    if let idx = args.firstIndex(of: "--stream"), idx + 1 < args.count,
       let p = UInt16(args[idx + 1]) {
        return p
    }
    return 5555
}()

let width = 1920
let height = 1200
let frameRate = 60
let bitrateMbps = 20
let testDuration: TimeInterval = streamMode ? 300 : 5  // 5min stream, 5s file

print("========================================")
print("  StreamTest - Pipeline Tester")
print("========================================")
print("Resolution: \(width)x\(height) @ \(frameRate)fps")
print("Bitrate: \(bitrateMbps) Mbps")
print("Mode: \(streamMode ? "STREAM (TCP port \(port))" : "FILE ONLY")")
print("")

// --- Setup components ---

let generator = TestPatternGenerator(width: width, height: height)
let encoder = TestEncoder(width: width, height: height, frameRate: frameRate, bitrateMbps: bitrateMbps)

// H.265 file output
let h265URL = URL(fileURLWithPath: "/tmp/streamtest.h265")
FileManager.default.createFile(atPath: h265URL.path, contents: nil)
let h265File = FileHandle(forWritingAtPath: h265URL.path)!

// TCP server (if streaming)
var server: TestServer?
if streamMode {
    server = TestServer(port: port)

    server?.onClientConnected = {
        print("[EVENT] Client connected - sending display config + keyframe")
        server?.sendDisplaySize(width: width, height: height, rotation: 0)
        // Force keyframe so client can start decoding
        encoder.requestKeyframe()
    }

    server?.onClientDisconnected = {
        print("[EVENT] Client disconnected")
    }

    server?.start()

    // Setup ADB reverse
    print("")
    print("Setting up ADB reverse...")
    let adbProcess = Process()
    adbProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    adbProcess.arguments = ["adb", "reverse", "tcp:\(port)", "tcp:\(port)"]
    let adbPipe = Pipe()
    adbProcess.standardOutput = adbPipe
    adbProcess.standardError = adbPipe
    do {
        try adbProcess.run()
        adbProcess.waitUntilExit()
        let output = String(data: adbPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if adbProcess.terminationStatus == 0 {
            print("[OK] ADB reverse: tcp:\(port) -> tcp:\(port)")
        } else {
            print("[WARN] ADB reverse failed: \(output)")
            print("       Run manually: adb reverse tcp:\(port) tcp:\(port)")
        }
    } catch {
        print("[WARN] ADB not found: \(error.localizedDescription)")
    }
}

// --- Stats tracking ---
var totalFramesEncoded: UInt64 = 0
var totalKeyframes: UInt64 = 0
var totalBytes: UInt64 = 0
var firstFrameSize = 0

// --- Encoder output handler ---
encoder.onEncodedFrame = { data, isKeyframe in
    totalFramesEncoded += 1
    totalBytes += UInt64(data.count)
    if isKeyframe { totalKeyframes += 1 }

    if totalFramesEncoded == 1 {
        firstFrameSize = data.count
        // Analyze first keyframe NAL units
        print("")
        print("--- First keyframe analysis ---")
        analyzeNALUnits(data)
        print("-------------------------------")
        print("")
    }

    // Always write to file
    h265File.write(data)

    // Send to tablet if streaming
    server?.sendFrame(data, isKeyframe: isKeyframe)

    // Progress log
    if totalFramesEncoded <= 5 || totalFramesEncoded % 60 == 0 {
        let kb = data.count / 1024
        let totalKB = totalBytes / 1024
        let type = isKeyframe ? "KEY" : "P"
        print("  Frame \(totalFramesEncoded) [\(type)]: \(kb)KB (total: \(totalKB)KB, keyframes: \(totalKeyframes))")
    }
}

// --- Main encode loop ---
print("")
if streamMode {
    print("Waiting for client to connect on port \(port)...")
    print("(Encoding starts immediately, streaming when client connects)")
}
print("Encoding \(testDuration)s of test pattern...")
print("")

let encodeQueue = DispatchQueue(label: "encode", qos: .userInteractive)
let startTime = DispatchTime.now()
var frameNum: UInt64 = 0
let frameDuration = 1.0 / Double(frameRate)

let timer = DispatchSource.makeTimerSource(queue: encodeQueue)
timer.schedule(deadline: .now(), repeating: frameDuration)
timer.setEventHandler {
    frameNum += 1
    let pts = CMTime(value: CMTimeValue(frameNum), timescale: CMTimeScale(frameRate))

    guard let pixelBuffer = generator.nextFrame() else {
        print("[WARN] Failed to generate frame \(frameNum)")
        return
    }

    encoder.encode(pixelBuffer: pixelBuffer, presentationTimeStamp: pts)
}
timer.resume()

// Run for testDuration seconds (or indefinitely in stream mode)
if streamMode {
    print("Press Ctrl+C to stop streaming")
    // Handle SIGINT gracefully
    signal(SIGINT) { _ in
        print("\n\nStopping...")
        exit(0)
    }
    // Run forever
    dispatchMain()
} else {
    // File-only mode: run for testDuration then exit
    Thread.sleep(forTimeInterval: testDuration)
    timer.cancel()

    // Wait for encoder to flush
    Thread.sleep(forTimeInterval: 0.5)

    h265File.closeFile()

    print("")
    print("========================================")
    print("  Results")
    print("========================================")
    print("Frames encoded: \(totalFramesEncoded)")
    print("Keyframes: \(totalKeyframes)")
    print("Total size: \(totalBytes / 1024)KB (\(totalBytes / 1024 / 1024)MB)")
    print("First keyframe: \(firstFrameSize) bytes")
    print("Avg frame: \(totalFramesEncoded > 0 ? totalBytes / totalFramesEncoded : 0) bytes")
    print("")
    print("H.265 bitstream saved to: /tmp/streamtest.h265")
    print("")
    print("Verify with:")
    print("  ffplay /tmp/streamtest.h265")
    print("  ffprobe -show_frames /tmp/streamtest.h265 | head -100")
    print("")
    server?.printStats()
    server?.stop()
}

// --- NAL unit analyzer ---
func analyzeNALUnits(_ data: Data) {
    var offset = 0
    var nalIndex = 0
    let bytes = [UInt8](data)

    while offset < bytes.count - 4 {
        // Find start code
        if bytes[offset] == 0 && bytes[offset+1] == 0 && bytes[offset+2] == 0 && bytes[offset+3] == 1 {
            offset += 4
            if offset >= bytes.count { break }

            // HEVC NAL header: 2 bytes
            // NAL type = (first_byte >> 1) & 0x3F
            let nalType = (bytes[offset] >> 1) & 0x3F
            let typeName: String
            switch nalType {
            case 32: typeName = "VPS (Video Parameter Set)"
            case 33: typeName = "SPS (Sequence Parameter Set)"
            case 34: typeName = "PPS (Picture Parameter Set)"
            case 19, 20: typeName = "IDR (Keyframe)"
            case 1: typeName = "P-slice (Non-IDR)"
            case 39: typeName = "SEI (Prefix)"
            case 40: typeName = "SEI (Suffix)"
            default: typeName = "Type \(nalType)"
            }

            // Find next start code to determine NAL size
            var nextStart = offset
            while nextStart < bytes.count - 4 {
                if bytes[nextStart] == 0 && bytes[nextStart+1] == 0 && bytes[nextStart+2] == 0 && bytes[nextStart+3] == 1 {
                    break
                }
                nextStart += 1
            }
            let nalSize = (nextStart >= bytes.count - 4) ? (bytes.count - offset) : (nextStart - offset)

            print("  NAL #\(nalIndex): \(typeName), \(nalSize) bytes")
            nalIndex += 1
        } else {
            offset += 1
        }
    }
    print("  Total NAL units: \(nalIndex)")
}
