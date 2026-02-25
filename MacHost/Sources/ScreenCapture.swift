import Foundation
@preconcurrency import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreGraphics
import CoreVideo
import IOSurface

// MARK: - SCStreamDelegate

private class StreamDelegate: NSObject, SCStreamDelegate {
    var onStreamError: ((Error) -> Void)?

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let nsError = error as NSError
        debugLog("SCStream stopped with error — domain: \(nsError.domain), code: \(nsError.code), description: \(nsError.localizedDescription)")
        onStreamError?(error)
    }
}

// MARK: - ScreenCapture

class ScreenCapture {
    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var streamDelegate: StreamDelegate?
    private var encoder: VideoEncoder?
    private var display: SCDisplay?
    private var virtualDisplayID: CGDirectDisplayID?
    private var refreshRate: Int = 60

    // Continuous frame-flow monitor
    private var lastFrameTime: DispatchTime?
    private var frameMonitorTimer: DispatchSourceTimer?
    private var hasReceivedFirstFrame = false
    private var restartAttempted = false

    // CGDisplayStream fallback
    private var cgDisplayStream: CGDisplayStream?
    private var fallbackActive = false

    // Streaming parameters (saved for restart)
    private weak var currentServer: StreamingServer?
    private var currentBitrateMbps: Int = 20
    private var currentQuality: String = "medium"
    private var currentGamingBoost: Bool = false
    private var currentFrameRate: Int = 60

    /// Callback when capture method changes (e.g. SCStream → CGDisplayStream fallback)
    var onCaptureMethodChanged: ((String) -> Void)?

    var displayWidth: Int { display?.width ?? Int(CGDisplayPixelsWide(virtualDisplayID ?? 0)) }
    var displayHeight: Int { display?.height ?? Int(CGDisplayPixelsHigh(virtualDisplayID ?? 0)) }

    init() async throws {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        debugLog("ScreenCapture init — macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
    }

    /// Setup screen capture for a specific virtual display
    func setupForVirtualDisplay(_ displayID: CGDirectDisplayID, refreshRate: Int = 60) async throws {
        self.virtualDisplayID = displayID
        self.refreshRate = refreshRate
        try await setupDisplay()
        try await setupStream()
    }

    // MARK: - SCShareableContent with timeout

    private func getShareableContentWithTimeout(seconds: Int = 10) async throws -> SCShareableContent {
        try await withThrowingTaskGroup(of: SCShareableContent.self) { group in
            group.addTask {
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                throw NSError(domain: "ScreenCapture", code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "SCShareableContent timed out after \(seconds)s (possible Apple bug FB12114396)"])
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Display setup

    private func setupDisplay() async throws {
        guard let virtualDisplayID = virtualDisplayID else {
            throw NSError(domain: "ScreenCapture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Virtual display ID not set"])
        }

        for attempt in 1...5 {
            let content: SCShareableContent
            do {
                content = try await getShareableContentWithTimeout(seconds: 10)
            } catch {
                debugLog("SCShareableContent attempt \(attempt) failed: \(error.localizedDescription)")
                if attempt < 5 {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                throw error
            }

            debugLog("SCShareableContent returned \(content.displays.count) displays: \(content.displays.map { $0.displayID })")

            if let virtualDisplay = content.displays.first(where: { $0.displayID == virtualDisplayID }) {
                display = virtualDisplay
                debugLog("Capturing virtual display: \(virtualDisplay.width)x\(virtualDisplay.height) (ID: \(virtualDisplayID))")
                return
            }

            if attempt < 5 {
                debugLog("Virtual display \(virtualDisplayID) not found in attempt \(attempt), retrying...")
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        throw NSError(domain: "ScreenCapture", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Virtual display with ID \(virtualDisplayID) not found after 5 attempts"])
    }

    // MARK: - Stream setup

    private func setupStream() async throws {
        guard let display = display else {
            throw NSError(domain: "ScreenCapture", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Display not initialized"])
        }

        let width = display.width
        let height = display.height
        let fps = refreshRate

        streamOutput = StreamOutput()

        let delegate = StreamDelegate()
        delegate.onStreamError = { [weak self] error in
            guard let self = self else { return }
            debugLog("StreamDelegate error callback — attempting fallback")
            if !self.fallbackActive {
                self.attemptFallbackCapture()
            }
        }
        streamDelegate = delegate

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.showsCursor = true
        config.queueDepth = 4
        config.capturesAudio = false
        config.backgroundColor = .clear
        config.scalesToFit = false

        let scStream = SCStream(filter: filter, configuration: config, delegate: delegate)
        try scStream.addStreamOutput(streamOutput!, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))

        stream = scStream
        debugLog("Stream configured: \(width)x\(height) @ \(fps)fps (with delegate)")
    }

    // MARK: - Start streaming

    func startStreaming(to server: StreamingServer?, bitrateMbps: Int = 20, quality: String = "medium", gamingBoost: Bool = false, frameRate: Int = 60) {
        // Save parameters for potential restart
        currentServer = server
        currentBitrateMbps = bitrateMbps
        currentQuality = quality
        currentGamingBoost = gamingBoost
        currentFrameRate = frameRate

        let width = displayWidth
        let height = displayHeight

        encoder = VideoEncoder(width: width, height: height, bitrateMbps: bitrateMbps, quality: quality, gamingBoost: gamingBoost, frameRate: frameRate)
        encoder?.onEncodedFrame = { [weak server] data, timestamp, isKeyframe in
            server?.sendFrame(data, timestamp: timestamp, isKeyframe: isKeyframe)
        }

        let encodeQueue = DispatchQueue(label: "encodeQueue", qos: .userInteractive)

        // Encode queue depth limit — drop frames if encoder falls behind
        var pendingEncodes: Int32 = 0

        // Cache last valid pixel buffer for re-encoding when SCStream sends idle frames
        var lastPixelBuffer: CVPixelBuffer?

        // Reset frame monitor state
        lastFrameTime = nil
        hasReceivedFirstFrame = false

        streamOutput?.onFrameReceived = { [weak self] sampleBuffer in
            guard let self = self else { return }

            // Update frame timestamp on every frame for flow monitor
            self.lastFrameTime = DispatchTime.now()

            if !self.hasReceivedFirstFrame {
                self.hasReceivedFirstFrame = true
                debugLog("First frame received from SCStream")
                self.onCaptureMethodChanged?("SCStream")
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            // Backpressure: skip if encode queue already has 2+ frames pending
            let pending = OSAtomicAdd32(0, &pendingEncodes)
            if pending >= 2 {
                return
            }

            if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                // Pass IOSurface-backed buffer directly to encoder — no copy needed.
                // VTCompressionSession retains the pixel buffer during encoding.
                // queueDepth=4 ensures SCStream has spare slots while encoder holds buffers.
                lastPixelBuffer = imageBuffer
                OSAtomicIncrement32(&pendingEncodes)
                encodeQueue.async {
                    self.encoder?.encode(pixelBuffer: imageBuffer, presentationTimeStamp: pts)
                    OSAtomicDecrement32(&pendingEncodes)
                }
            } else if let cached = lastPixelBuffer {
                OSAtomicIncrement32(&pendingEncodes)
                encodeQueue.async {
                    self.encoder?.encode(pixelBuffer: cached, presentationTimeStamp: pts)
                    OSAtomicDecrement32(&pendingEncodes)
                }
            }
        }

        Task {
            do {
                try await stream?.startCapture()
                debugLog("SCStream capture started — starting frame flow monitor (3s interval, 5s timeout)")
                startFrameMonitor()
            } catch {
                debugLog("Failed to start SCStream capture: \(error)")
                debugLog("Attempting CGDisplayStream fallback due to start failure")
                attemptFallbackCapture()
            }
        }
    }

    // MARK: - Continuous frame-flow monitor

    private func startFrameMonitor() {
        stopFrameMonitor()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 3.0, repeating: 3.0)
        timer.setEventHandler { [weak self] in
            guard let self = self, !self.fallbackActive else {
                self?.stopFrameMonitor()
                return
            }

            let stalled: Bool
            if let last = self.lastFrameTime {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - last.uptimeNanoseconds) / 1_000_000_000
                stalled = elapsed > 5.0
                if stalled {
                    debugLog("Frame flow stalled — no frames for \(String(format: "%.1f", elapsed))s, triggering fallback")
                }
            } else {
                stalled = true
                debugLog("Frame flow stalled — no frames ever received after 5s, triggering fallback")
            }

            if stalled {
                self.stopFrameMonitor()
                if !self.restartAttempted {
                    debugLog("Attempting SCStream restart...")
                    self.restartStream()
                } else {
                    debugLog("Restart already attempted — falling back to CGDisplayStream")
                    self.attemptFallbackCapture()
                }
            }
        }
        timer.resume()
        frameMonitorTimer = timer
    }

    private func stopFrameMonitor() {
        frameMonitorTimer?.cancel()
        frameMonitorTimer = nil
    }

    // MARK: - Stream restart

    private func restartStream() {
        restartAttempted = true
        hasReceivedFirstFrame = false

        Task {
            do {
                // Stop existing stream
                try? await stream?.stopCapture()
                stream = nil
                streamOutput = nil
                streamDelegate = nil
                display = nil

                // Re-setup
                try await setupDisplay()
                try await setupStream()

                // Re-attach encoding pipeline
                let encodeQueue = DispatchQueue(label: "encodeQueue.restart", qos: .userInteractive)
                var pendingEncodes: Int32 = 0
                var lastPixelBuffer: CVPixelBuffer?

                streamOutput?.onFrameReceived = { [weak self] sampleBuffer in
                    guard let self = self else { return }

                    self.lastFrameTime = DispatchTime.now()

                    if !self.hasReceivedFirstFrame {
                        self.hasReceivedFirstFrame = true
                        debugLog("First frame received after SCStream restart")
                        self.onCaptureMethodChanged?("SCStream")
                    }

                    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let pending = OSAtomicAdd32(0, &pendingEncodes)
                    if pending >= 2 { return }

                    if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                        lastPixelBuffer = imageBuffer
                        OSAtomicIncrement32(&pendingEncodes)
                        encodeQueue.async {
                            self.encoder?.encode(pixelBuffer: imageBuffer, presentationTimeStamp: pts)
                            OSAtomicDecrement32(&pendingEncodes)
                        }
                    } else if let cached = lastPixelBuffer {
                        OSAtomicIncrement32(&pendingEncodes)
                        encodeQueue.async {
                            self.encoder?.encode(pixelBuffer: cached, presentationTimeStamp: pts)
                            OSAtomicDecrement32(&pendingEncodes)
                        }
                    }
                }

                try await stream?.startCapture()
                debugLog("SCStream restarted — starting frame flow monitor")
                startFrameMonitor()
            } catch {
                debugLog("SCStream restart failed: \(error) — falling back to CGDisplayStream")
                attemptFallbackCapture()
            }
        }
    }

    // MARK: - CGDisplayStream fallback

    private func attemptFallbackCapture() {
        guard let displayID = virtualDisplayID, !fallbackActive else {
            debugLog("Fallback skipped — no displayID or already active")
            return
        }
        fallbackActive = true

        // Stop SCStream if still running
        Task {
            try? await stream?.stopCapture()
            stream = nil
            streamOutput = nil
            streamDelegate = nil
        }

        let width = Int(CGDisplayPixelsWide(displayID))
        let height = Int(CGDisplayPixelsHigh(displayID))

        debugLog("CGDisplayStream fallback — display \(displayID) (\(width)x\(height))")

        let pixelFormat = Int32(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        let queue = DispatchQueue(label: "com.sidescreen.cgdisplaystream", qos: .userInteractive)

        guard let displayStream = CGDisplayStream(
            dispatchQueueDisplay: displayID,
            outputWidth: width,
            outputHeight: height,
            pixelFormat: pixelFormat,
            properties: nil,
            queue: queue,
            handler: { [weak self] status, displayTime, frameSurface, updateRef in
                guard let self = self, let surface = frameSurface else { return }

                var unmanagedPB: Unmanaged<CVPixelBuffer>?
                let attrs: [String: Any] = [
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
                ]
                let cvReturn = CVPixelBufferCreateWithIOSurface(
                    kCFAllocatorDefault,
                    surface,
                    attrs as CFDictionary,
                    &unmanagedPB
                )

                guard cvReturn == kCVReturnSuccess, let pb = unmanagedPB?.takeRetainedValue() else { return }

                let pts = CMTime(value: CMTimeValue(displayTime), timescale: 1_000_000_000)
                self.encoder?.encode(pixelBuffer: pb, presentationTimeStamp: pts)
            }
        ) else {
            debugLog("Failed to create CGDisplayStream — fallback unavailable")
            fallbackActive = false
            return
        }

        let startResult = displayStream.start()
        if startResult == .success {
            cgDisplayStream = displayStream
            debugLog("CGDisplayStream fallback started successfully")
            onCaptureMethodChanged?("CGDisplayStream (fallback)")
        } else {
            debugLog("CGDisplayStream.start() failed: \(startResult)")
            fallbackActive = false
        }
    }

    // MARK: - Settings update

    func updateEncoderSettings(bitrateMbps: Int, quality: String, gamingBoost: Bool) {
        encoder?.updateSettings(bitrateMbps: bitrateMbps, quality: quality, gamingBoost: gamingBoost)
    }

    // MARK: - Stop streaming

    func stopStreaming() {
        // Cancel frame flow monitor
        stopFrameMonitor()

        // Stop SCStream
        Task {
            do {
                try await stream?.stopCapture()
            } catch {
                debugLog("Failed to stop SCStream capture: \(error)")
            }
        }

        // Stop CGDisplayStream fallback
        if fallbackActive {
            cgDisplayStream?.stop()
            cgDisplayStream = nil
            fallbackActive = false
            debugLog("CGDisplayStream fallback stopped")
        }

        // Reset state
        lastFrameTime = nil
        hasReceivedFirstFrame = false
        restartAttempted = false
    }
}

// MARK: - StreamOutput

class StreamOutput: NSObject, SCStreamOutput {
    var onFrameReceived: ((CMSampleBuffer) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        onFrameReceived?(sampleBuffer)
    }
}
