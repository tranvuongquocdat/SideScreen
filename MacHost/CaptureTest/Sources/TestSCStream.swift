import ScreenCaptureKit
import CoreMedia
import Foundation

/// Delegate class to receive frames from SCStream
@available(macOS 14.0, *)
private class SCStreamFrameHandler: NSObject, SCStreamOutput, SCStreamDelegate {
    let startTime: CFAbsoluteTime
    let targetFrames: Int
    var frameCount = 0
    let semaphore: DispatchSemaphore

    init(startTime: CFAbsoluteTime, targetFrames: Int, semaphore: DispatchSemaphore) {
        self.startTime = startTime
        self.targetFrames = targetFrames
        self.semaphore = semaphore
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }

        frameCount += 1
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("  Frame \(frameCount): time=\(String(format: "%.3f", elapsed))s")

        if frameCount >= targetFrames {
            semaphore.signal()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("  Stream stopped with error at \(String(format: "%.3f", elapsed))s: \(error.localizedDescription)")
        semaphore.signal()
    }
}

/// Internal async implementation for SCStream test
@available(macOS 14.0, *)
private func _testSCStreamAsync(
    displayID: CGDirectDisplayID,
    timeout: TimeInterval
) async -> (success: Bool, frameCount: Int, elapsed: TimeInterval) {
    let startTime = CFAbsoluteTimeGetCurrent()
    let targetFrames = 5
    let semaphore = DispatchSemaphore(value: 0)

    // Get shareable content
    print("  Fetching shareable content...")
    let content: SCShareableContent
    do {
        content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    } catch {
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("  [FAIL] Failed to get shareable content: \(error.localizedDescription)")
        return (success: false, frameCount: 0, elapsed: elapsed)
    }

    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let availableIDs = content.displays.map { $0.displayID }
        print("  Available display IDs: \(availableIDs)")
        print("  [FAIL] Display \(displayID) not found in shareable content")
        return (success: false, frameCount: 0, elapsed: elapsed)
    }

    print("  Found display: \(display.width)x\(display.height) (ID: \(display.displayID))")

    // Create SCStream
    let handler = SCStreamFrameHandler(
        startTime: startTime,
        targetFrames: targetFrames,
        semaphore: semaphore
    )

    let filter = SCContentFilter(display: display, excludingWindows: [])

    let config = SCStreamConfiguration()
    config.width = display.width
    config.height = display.height
    config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.capturesAudio = false
    config.queueDepth = 3

    let stream = SCStream(filter: filter, configuration: config, delegate: handler)

    // Add output and start on background thread (may hang due to CoreAudio HAL)
    print("  Creating SCStream (WARNING: this may hang on macOS 26.x due to CoreAudio HAL deadlock)...")

    let streamQueue = DispatchQueue(label: "com.capturetest.scstream.frames")
    let startSemaphore = DispatchSemaphore(value: 0)
    var streamStartError: Error?

    let bgQueue = DispatchQueue(label: "com.capturetest.scstream.setup")
    bgQueue.async {
        do {
            try stream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: streamQueue)
        } catch {
            streamStartError = error
            startSemaphore.signal()
            return
        }

        stream.startCapture { error in
            if let error = error {
                streamStartError = error
            }
            startSemaphore.signal()
        }
    }

    // Wait for stream start with timeout (this is where it may hang)
    let startWait = startSemaphore.wait(timeout: .now() + timeout)
    if startWait == .timedOut {
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("  [FAIL] SCStream.startCapture() HUNG for \(String(format: "%.2f", elapsed))s (CoreAudio HAL deadlock)")
        return (success: false, frameCount: 0, elapsed: elapsed)
    }

    if let error = streamStartError {
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("  [FAIL] SCStream start error: \(error.localizedDescription)")
        return (success: false, frameCount: 0, elapsed: elapsed)
    }

    print("  Stream started. Waiting for \(targetFrames) frames (timeout: \(Int(timeout))s)...")

    let waitResult = semaphore.wait(timeout: .now() + timeout)
    let elapsed = CFAbsoluteTimeGetCurrent() - startTime

    // Stop stream on background thread (may also hang)
    let stopSemaphore = DispatchSemaphore(value: 0)
    bgQueue.async {
        stream.stopCapture { _ in
            stopSemaphore.signal()
        }
    }
    _ = stopSemaphore.wait(timeout: .now() + 3.0)

    let finalFrameCount = handler.frameCount

    if waitResult == .timedOut {
        print("  [FAIL] Timed out after \(String(format: "%.2f", elapsed))s with \(finalFrameCount) frames")
        return (success: false, frameCount: finalFrameCount, elapsed: elapsed)
    }

    print("  [OK] Received \(finalFrameCount) frames in \(String(format: "%.2f", elapsed))s")
    return (success: true, frameCount: finalFrameCount, elapsed: elapsed)
}

/// Test SCStream (ScreenCaptureKit) capture API
/// - Parameters:
///   - displayID: The display to capture
///   - timeout: Maximum time to wait for frames
/// - Returns: Tuple with success status, frame count, and elapsed time
func testSCStream(
    displayID: CGDirectDisplayID,
    timeout: TimeInterval = 10.0
) -> (success: Bool, frameCount: Int, elapsed: TimeInterval) {
    guard #available(macOS 14.0, *) else {
        print("  [FAIL] SCStream requires macOS 14.0+")
        return (success: false, frameCount: 0, elapsed: 0)
    }

    // Run async code synchronously using a semaphore
    var result: (success: Bool, frameCount: Int, elapsed: TimeInterval) = (false, 0, 0)
    let doneSemaphore = DispatchSemaphore(value: 0)

    let queue = DispatchQueue(label: "com.capturetest.scstream.runner")
    queue.async {
        let asyncResult = Task {
            await _testSCStreamAsync(displayID: displayID, timeout: timeout)
        }
        let semInner = DispatchSemaphore(value: 0)
        Task {
            result = await asyncResult.value
            semInner.signal()
        }
        semInner.wait()
        doneSemaphore.signal()
    }

    // Overall timeout: test timeout + 5s buffer
    let overallWait = doneSemaphore.wait(timeout: .now() + timeout + 5.0)
    if overallWait == .timedOut {
        let elapsed = timeout + 5.0
        print("  [FAIL] Overall SCStream test timed out after \(String(format: "%.2f", elapsed))s")
        return (success: false, frameCount: 0, elapsed: elapsed)
    }

    return result
}
