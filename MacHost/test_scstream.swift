import Foundation
import AppKit
@preconcurrency import ScreenCaptureKit
import CoreMedia

func log(_ msg: String) {
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    print("[\(ts)] \(msg)", terminator: "\n")
    fflush(stdout)
}

log("=== SCStream Init Test (macOS \(ProcessInfo.processInfo.operatingSystemVersionString)) ===")
log("PID: \(ProcessInfo.processInfo.processIdentifier)")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Use Task for async, but keep it simple
Task { @MainActor in
    do {
        log("1. Getting shareable content...")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        log("   Found \(content.displays.count) displays: \(content.displays.map { "\($0.displayID) (\($0.width)x\($0.height))" })")

        guard let display = content.displays.first else {
            log("❌ No displays"); exit(1)
        }

        log("2. Creating filter + config (MainActor, isMain=\(Thread.isMainThread))")
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.showsCursor = true
        config.queueDepth = 2
        config.capturesAudio = false
        log("   Filter + Config ✅")

        log("3. SCStream init on MainActor...")
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        log("   SCStream ✅")

        class Output: NSObject, SCStreamOutput {
            var count = 0
            func stream(_ s: SCStream, didOutputSampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
                count += 1
                if count <= 3 { log("   📹 Frame \(count)") }
            }
        }
        let output = Output()
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global())
        log("4. Output added ✅")

        log("5. startCapture...")
        try await stream.startCapture()
        log("   Capture started ✅")

        try await Task.sleep(nanoseconds: 3_000_000_000)
        log("6. Received \(output.count) frames")

        try await stream.stopCapture()
        log("   Stopped ✅")
        log("🎉 ALL TESTS PASSED")
    } catch {
        log("❌ Error: \(error)")
    }
    exit(0)
}

DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
    log("⏰ TIMEOUT after 20s")
    exit(1)
}

app.run()
