import Foundation
@preconcurrency import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreGraphics

class ScreenCapture {
    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var encoder: VideoEncoder?
    private var display: SCDisplay?
    private var virtualDisplayID: CGDirectDisplayID?
    private var refreshRate: Int = 60

    var displayWidth: Int { display?.width ?? 1920 }
    var displayHeight: Int { display?.height ?? 1080 }

    init() async throws {}

    /// Setup screen capture for a specific virtual display
    func setupForVirtualDisplay(_ displayID: CGDirectDisplayID, refreshRate: Int = 60) async throws {
        self.virtualDisplayID = displayID
        self.refreshRate = refreshRate
        try await setupDisplay()
        try await setupStream()
    }

    private func setupDisplay() async throws {
        guard let virtualDisplayID = virtualDisplayID else {
            throw NSError(domain: "ScreenCapture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Virtual display ID not set"])
        }

        for attempt in 1...5 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

            if let virtualDisplay = content.displays.first(where: { $0.displayID == virtualDisplayID }) {
                display = virtualDisplay
                debugLog("Capturing virtual display: \(virtualDisplay.width)x\(virtualDisplay.height) (ID: \(virtualDisplayID))")
                return
            }

            if attempt < 5 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        throw NSError(domain: "ScreenCapture", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Virtual display with ID \(virtualDisplayID) not found after 5 attempts"])
    }

    private func setupStream() async throws {
        guard let display = display else {
            throw NSError(domain: "ScreenCapture", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Display not initialized"])
        }

        let width = display.width
        let height = display.height
        let fps = refreshRate

        streamOutput = StreamOutput()

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

        let scStream = SCStream(filter: filter, configuration: config, delegate: nil)
        try scStream.addStreamOutput(streamOutput!, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))

        stream = scStream
        debugLog("Stream configured: \(width)x\(height) @ \(fps)fps")
    }

    func startStreaming(to server: StreamingServer?, bitrateMbps: Int = 20, quality: String = "medium", gamingBoost: Bool = false, frameRate: Int = 60) {
        let width = display?.width ?? 1920
        let height = display?.height ?? 1080

        encoder = VideoEncoder(width: width, height: height, bitrateMbps: bitrateMbps, quality: quality, gamingBoost: gamingBoost, frameRate: frameRate)
        encoder?.onEncodedFrame = { [weak server] data, timestamp, isKeyframe in
            server?.sendFrame(data, timestamp: timestamp, isKeyframe: isKeyframe)
        }

        let encodeQueue = DispatchQueue(label: "encodeQueue", qos: .userInteractive)

        // Encode queue depth limit — drop frames if encoder falls behind
        var pendingEncodes: Int32 = 0

        // Cache last valid pixel buffer for re-encoding when SCStream sends idle frames
        var lastPixelBuffer: CVPixelBuffer?

        streamOutput?.onFrameReceived = { [weak self] sampleBuffer in
            guard let self = self else { return }
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
                debugLog("SCStream capture started")
            } catch {
                debugLog("Failed to start capture: \(error)")
            }
        }
    }

    func updateEncoderSettings(bitrateMbps: Int, quality: String, gamingBoost: Bool) {
        encoder?.updateSettings(bitrateMbps: bitrateMbps, quality: quality, gamingBoost: gamingBoost)
    }

    func stopStreaming() {
        Task {
            do {
                try await stream?.stopCapture()
            } catch {
                debugLog("Failed to stop capture: \(error)")
            }
        }
    }
}

class StreamOutput: NSObject, SCStreamOutput {
    var onFrameReceived: ((CMSampleBuffer) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        onFrameReceived?(sampleBuffer)
    }
}
