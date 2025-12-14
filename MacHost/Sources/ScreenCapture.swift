import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreGraphics

class ScreenCapture {
    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var encoder: VideoEncoder?
    private var display: SCDisplay?
    private var virtualDisplayID: CGDirectDisplayID?

    var displayWidth: Int { display?.width ?? 1920 }
    var displayHeight: Int { display?.height ?? 1080 }

    init() async throws {
        // Initial setup will be done when we have the virtual display ID
    }

    /// Setup screen capture for a specific virtual display
    /// - Parameter displayID: The CGDirectDisplayID of the virtual display to capture
    func setupForVirtualDisplay(_ displayID: CGDirectDisplayID) async throws {
        self.virtualDisplayID = displayID
        try await setupDisplay()
        try await setupStream()
    }

    private func setupDisplay() async throws {
        guard let virtualDisplayID = virtualDisplayID else {
            throw NSError(domain: "ScreenCapture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Virtual display ID not set"])
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        // Find our virtual display by displayID
        if let virtualDisplay = content.displays.first(where: { $0.displayID == virtualDisplayID }) {
            display = virtualDisplay
            print("📺 Capturing virtual display: \(virtualDisplay.width)x\(virtualDisplay.height) (ID: \(virtualDisplayID))")
        } else {
            throw NSError(domain: "ScreenCapture", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Virtual display with ID \(virtualDisplayID) not found in shareable content"])
        }
    }

    private func setupStream() async throws {
        guard let display = display else {
            throw NSError(domain: "ScreenCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Display not initialized"])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height

        // Set to exactly 60fps (1/60 = 16.67ms per frame)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)

        // Pixel format optimized for H.265 encoding
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

        // Display settings
        config.showsCursor = true

        // Reduce queue depth for lower latency (trade memory for speed)
        config.queueDepth = 3

        // No audio
        config.capturesAudio = false
        config.sampleRate = 0
        config.channelCount = 0

        // Disable background blur and other effects for performance
        config.backgroundColor = .clear
        config.scalesToFit = false

        streamOutput = StreamOutput()
        stream = SCStream(filter: filter, configuration: config, delegate: nil)

        // Use high priority queue for minimal latency
        try stream?.addStreamOutput(streamOutput!, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))

        print("✅ Stream configured: \(config.width)x\(config.height) @ 60fps (low-latency mode)")
    }

    func startStreaming(to server: StreamingServer?) {
        let width = display?.width ?? 1920
        let height = display?.height ?? 1080

        server?.setDisplaySize(width: width, height: height)

        encoder = VideoEncoder(width: width, height: height)
        encoder?.onEncodedFrame = { [weak server] data in
            server?.sendFrame(data)
        }

        streamOutput?.onFrameReceived = { [weak self] sampleBuffer in
            self?.encoder?.encode(sampleBuffer: sampleBuffer)
        }

        Task {
            do {
                try await stream?.startCapture()
                print("✅ Capture started")
            } catch {
                print("❌ Failed to start capture: \(error)")
            }
        }
    }

    func stopStreaming() {
        Task {
            do {
                try await stream?.stopCapture()
                print("⏹️  Capture stopped")
            } catch {
                print("❌ Failed to stop capture: \(error)")
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
