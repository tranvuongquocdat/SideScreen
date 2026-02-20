import AVFoundation
import CoreMedia
import Foundation

/// Delegate class to receive video frames from AVCaptureSession
private class AVCaptureFrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let startTime: CFAbsoluteTime
    let targetFrames: Int
    var frameCount = 0
    let semaphore: DispatchSemaphore

    init(startTime: CFAbsoluteTime, targetFrames: Int, semaphore: DispatchSemaphore) {
        self.startTime = startTime
        self.targetFrames = targetFrames
        self.semaphore = semaphore
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        frameCount += 1
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("  Frame \(frameCount): time=\(String(format: "%.3f", elapsed))s")

        if frameCount >= targetFrames {
            semaphore.signal()
        }
    }
}

/// Test AVCaptureScreenInput capture API
/// - Parameters:
///   - displayID: The display to capture
///   - timeout: Maximum time to wait for frames
/// - Returns: Tuple with success status, frame count, and elapsed time
func testAVCaptureScreenInput(
    displayID: CGDirectDisplayID,
    timeout: TimeInterval = 10.0
) -> (success: Bool, frameCount: Int, elapsed: TimeInterval) {
    let startTime = CFAbsoluteTimeGetCurrent()
    let targetFrames = 5
    let semaphore = DispatchSemaphore(value: 0)

    print("  Creating AVCaptureSession with AVCaptureScreenInput for display \(displayID)")

    let session = AVCaptureSession()
    let screenInput = AVCaptureScreenInput(displayID: displayID)

    guard let input = screenInput else {
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("  [FAIL] Failed to create AVCaptureScreenInput")
        return (success: false, frameCount: 0, elapsed: elapsed)
    }

    input.minFrameDuration = CMTime(value: 1, timescale: 60)

    guard session.canAddInput(input) else {
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("  [FAIL] Cannot add AVCaptureScreenInput to session")
        return (success: false, frameCount: 0, elapsed: elapsed)
    }
    session.addInput(input)

    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]

    let delegateQueue = DispatchQueue(label: "com.capturetest.avcapture")
    let delegate = AVCaptureFrameDelegate(
        startTime: startTime,
        targetFrames: targetFrames,
        semaphore: semaphore
    )
    output.setSampleBufferDelegate(delegate, queue: delegateQueue)

    guard session.canAddOutput(output) else {
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("  [FAIL] Cannot add AVCaptureVideoDataOutput to session")
        return (success: false, frameCount: 0, elapsed: elapsed)
    }
    session.addOutput(output)

    print("  Starting capture session. Waiting for \(targetFrames) frames (timeout: \(Int(timeout))s)...")
    session.startRunning()

    let waitResult = semaphore.wait(timeout: .now() + timeout)
    let elapsed = CFAbsoluteTimeGetCurrent() - startTime

    session.stopRunning()

    let finalFrameCount = delegate.frameCount

    if waitResult == .timedOut {
        print("  [FAIL] Timed out after \(String(format: "%.2f", elapsed))s with \(finalFrameCount) frames")
        return (success: false, frameCount: finalFrameCount, elapsed: elapsed)
    }

    print("  [OK] Received \(finalFrameCount) frames in \(String(format: "%.2f", elapsed))s")
    return (success: true, frameCount: finalFrameCount, elapsed: elapsed)
}
