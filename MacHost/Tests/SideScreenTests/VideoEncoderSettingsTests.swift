import XCTest
import CoreMedia
import CoreVideo
@testable import SideScreen

/// Changing the bitrate while streaming rebuilt the compression session on the
/// main thread under frames being encoded on the capture queue. VideoToolbox
/// reported -12903 (invalid session), its encoder service hung, and the app froze.
final class VideoEncoderSettingsTests: XCTestCase {
    private func makeEncoder() throws -> VideoEncoder {
        let encoder = VideoEncoder(width: 640, height: 400, codec: .hevc, bitrateMbps: 20, quality: "high", frameRate: 120)
        guard encoder.hasSession else {
            throw XCTSkip("No hardware HEVC encoder on this machine")
        }
        return encoder
    }

    private func makeFrame() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        CVPixelBufferCreate(kCFAllocatorDefault, 640, 400, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            attrs as CFDictionary, &buffer)
        return buffer!
    }

    private func pts(_ frame: Int) -> CMTime {
        CMTime(value: CMTimeValue(frame), timescale: 120)
    }

    func testSliderDragWhileStreamingKeepsEncoding() throws {
        let encoder = try makeEncoder()
        let frame = makeFrame()
        let outputs = OutputCounter()
        encoder.onEncodedFrame = { _, _, _ in outputs.increment() }

        let streaming = expectation(description: "frames keep flowing")
        let captureQueue = DispatchQueue(label: "test.capture", qos: .userInteractive)
        captureQueue.async {
            for i in 0..<240 {
                encoder.encode(pixelBuffer: frame, presentationTimeStamp: self.pts(i))
                usleep(2_000)
            }
            streaming.fulfill()
        }

        // A slider drag: many steps, a few quality changes, from another thread.
        for step in 0..<200 {
            encoder.updateSettings(bitrateMbps: 1000 + step * 20, quality: step % 50 == 49 ? "medium" : "high", gamingBoost: false)
            usleep(500)
        }

        wait(for: [streaming], timeout: 20)

        // Frames encoded after the drag still come out.
        let before = outputs.value
        for i in 240..<270 {
            encoder.encode(pixelBuffer: frame, presentationTimeStamp: pts(i))
        }
        let after = expectation(description: "output after the drag")
        DispatchQueue.global().async {
            for _ in 0..<200 where outputs.value <= before { usleep(10_000) }
            after.fulfill()
        }
        wait(for: [after], timeout: 5)
        XCTAssertGreaterThan(outputs.value, before)
        XCTAssertTrue(encoder.hasSession)
    }

    func testUpdateSettingsReturnsWithoutWaitingForTheEncoder() throws {
        let encoder = try makeEncoder()
        let start = Date()
        for step in 0..<1000 {
            encoder.updateSettings(bitrateMbps: 100 + step, quality: "high", gamingBoost: false)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    // MARK: - Average bitrate value

    func testBitrateIsCappedAtWhatVideoToolboxAccepts() {
        // 5000 Mbps (slider maximum) used to wrap to 705 Mbps; 2148-4294 were rejected.
        XCTAssertEqual(VideoEncoder.averageBitRateBps(bitrateMbps: 5000, gamingBoost: false), Int(Int32.max))
        XCTAssertEqual(VideoEncoder.averageBitRateBps(bitrateMbps: 3000, gamingBoost: false), Int(Int32.max))
        XCTAssertEqual(VideoEncoder.averageBitRateBps(bitrateMbps: 2147, gamingBoost: false), 2_147_000_000)
    }

    func testBitrateBelowTheCapIsUnchanged() {
        XCTAssertEqual(VideoEncoder.averageBitRateBps(bitrateMbps: 1540, gamingBoost: false), 1_540_000_000)
        XCTAssertEqual(VideoEncoder.averageBitRateBps(bitrateMbps: 20, gamingBoost: false), 60_000_000)
        XCTAssertEqual(VideoEncoder.averageBitRateBps(bitrateMbps: 50, gamingBoost: true), 50_000_000)
    }
}

private final class OutputCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }
}
