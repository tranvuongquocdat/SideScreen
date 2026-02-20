import CoreGraphics
import CoreVideo
import Foundation

/// Test CGDisplayStream capture API
/// - Parameters:
///   - displayID: The display to capture
///   - timeout: Maximum time to wait for frames
/// - Returns: Tuple with success status, frame count, and elapsed time
func testCGDisplayStream(
    displayID: CGDirectDisplayID,
    timeout: TimeInterval = 10.0
) -> (success: Bool, frameCount: Int, elapsed: TimeInterval) {
    let startTime = CFAbsoluteTimeGetCurrent()
    let targetFrames = 5
    var frameCount = 0
    let semaphore = DispatchSemaphore(value: 0)

    let width = CGDisplayPixelsWide(displayID)
    let height = CGDisplayPixelsHigh(displayID)

    print("  Creating CGDisplayStream for display \(displayID) (\(width)x\(height))")

    let pixelFormat = Int32(kCVPixelFormatType_32BGRA)

    guard let stream = CGDisplayStream(
        dispatchQueueDisplay: displayID,
        outputWidth: width,
        outputHeight: height,
        pixelFormat: pixelFormat,
        properties: nil,
        queue: DispatchQueue(label: "com.capturetest.cgdisplaystream"),
        handler: { status, displayTime, frameSurface, updateRef in
            frameCount += 1
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            print("  Frame \(frameCount): status=\(status.rawValue), time=\(String(format: "%.3f", elapsed))s")

            if frameCount >= targetFrames {
                semaphore.signal()
            }
        }
    ) else {
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("  [FAIL] Failed to create CGDisplayStream")
        return (success: false, frameCount: 0, elapsed: elapsed)
    }

    let startResult = stream.start()
    if startResult != CGError.success {
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("  [FAIL] CGDisplayStream.start() failed with error: \(startResult)")
        return (success: false, frameCount: 0, elapsed: elapsed)
    }

    print("  Stream started. Waiting for \(targetFrames) frames (timeout: \(Int(timeout))s)...")

    let waitResult = semaphore.wait(timeout: .now() + timeout)
    let elapsed = CFAbsoluteTimeGetCurrent() - startTime

    stream.stop()

    if waitResult == .timedOut {
        print("  [FAIL] Timed out after \(String(format: "%.2f", elapsed))s with \(frameCount) frames")
        return (success: false, frameCount: frameCount, elapsed: elapsed)
    }

    print("  [OK] Received \(frameCount) frames in \(String(format: "%.2f", elapsed))s")
    return (success: true, frameCount: frameCount, elapsed: elapsed)
}
