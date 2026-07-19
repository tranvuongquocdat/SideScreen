import Foundation
import AppKit
@preconcurrency import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreGraphics
import CoreVideo
import IOSurface
import IOKit.pwr_mgt
import os

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

    // Thread-safe state for cross-thread access (frame output queue + main queue)
    private let stateLock = OSAllocatedUnfairLock(initialState: FrameMonitorState())

    private struct FrameMonitorState {
        var lastFrameTime: DispatchTime?
        var hasReceivedFirstFrame = false
        var fallbackActive = false
    }

    private struct KeyframeRequestState {
        var pendingEncoderCreationRequest = false
        var lastKeyframeOrReplayRequestNs: UInt64 = 0
    }
    private let keyframeRequestLock = OSAllocatedUnfairLock(initialState: KeyframeRequestState())
    private static let keyframeRequestThrottleNs: UInt64 = 500_000_000

    // Main-thread-only state
    private var frameMonitorTimer: DispatchSourceTimer?
    private var restartAttempted = false
    private var wakeObservers: [NSObjectProtocol] = []
    /// True between startStreaming and stopStreaming. Guards wake-triggered
    /// restarts from re-enabling capture after a stop.
    private var isStreaming = false
    /// Bumped on every stopStreaming and every restart so a superseded
    /// in-flight restart Task aborts instead of resurrecting capture.
    private var streamGeneration: UInt64 = 0

    // Display-sleep assertion held while streaming (see createDisplaySleepAssertion)
    private var displaySleepAssertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var hasDisplaySleepAssertion = false
    private var wakeRestartPending = false

    // CGDisplayStream fallback
    private var cgDisplayStream: CGDisplayStream?

    // Streaming parameters (saved for restart)
    private weak var currentServer: StreamingServer?
    private var currentBitrateMbps: Int = 20
    private var currentQuality: String = "medium"
    private var currentGamingBoost: Bool = false
    private var currentFrameRate: Int = 60

    // Encoding pipeline state (captured by frame handler closure)
    private var encodeQueue: DispatchQueue?
    private var pendingEncodes: Int32 = 0
    private var lastPixelBuffer: CVPixelBuffer?

    /// Callback when capture method changes (e.g. SCStream → CGDisplayStream fallback)
    var onCaptureMethodChanged: ((String) -> Void)?

    /// Force the encoder to emit an IDR keyframe on the next frame.
    /// If the encoder hasn't been created yet (request arrived before
    /// startStreaming), the request is stored and applied at encoder init.
    func requestKeyframe() {
        if let encoder {
            encoder.requestKeyframe()
            return
        }
        keyframeRequestLock.withLock { $0.pendingEncoderCreationRequest = true }
    }

    /// Force a keyframe for the next captured frame, AND immediately re-encode
    /// the last cached frame as a forced keyframe if the display is currently
    /// idle. Without this, a client connecting during a static screen would
    /// wait up to one full GOP duration before its decoder could start.
    func requestKeyframeOrReplayCachedFrame(force: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        let shouldRequest = keyframeRequestLock.withLock { state -> Bool in
            if !force,
               state.lastKeyframeOrReplayRequestNs > 0,
               now - state.lastKeyframeOrReplayRequestNs < Self.keyframeRequestThrottleNs {
                return false
            }
            state.lastKeyframeOrReplayRequestNs = now
            return true
        }
        guard shouldRequest else { return }

        requestKeyframe()

        guard let encoder, let cached = lastPixelBuffer else { return }

        let pts = CMTime(
            value: CMTimeValue(DispatchTime.now().uptimeNanoseconds / 1000),
            timescale: 1_000_000
        )

        encodeQueue?.async {
            encoder.encode(pixelBuffer: cached, presentationTimeStamp: pts)
        }
    }

    var displayWidth: Int {
        guard let id = virtualDisplayID else { return display?.width ?? 0 }
        return ScreenCapture.physicalSize(for: id).width
    }
    var displayHeight: Int {
        guard let id = virtualDisplayID else { return display?.height ?? 0 }
        return ScreenCapture.physicalSize(for: id).height
    }

    /// Codec for the current encode session. Switching restarts the stream.
    private(set) var codec: StreamCodec = .hevc

    /// Decoder ceiling reported by the connected client (issue #41). Nil for
    /// legacy clients that report nothing.
    private var clientDecodeLimit: (width: Int, height: Int)?

    /// Encode dimensions for a codec: physical display pixels, clamped to the
    /// client's reported decoder limit when known, else to the conservative
    /// AVC floor when streaming H.264. SCStream/CGDisplayStream scale the
    /// capture into this size, so no virtual-display change is needed.
    func encodeSize(for codec: StreamCodec) -> (width: Int, height: Int) {
        let phys = (displayWidth, displayHeight)
        // A reported limit is authoritative for both codecs: it is what the
        // client's own MediaCodec claims it can decode.
        if let limit = clientDecodeLimit {
            return CodecLimits.clamp(width: phys.0, height: phys.1,
                                     maxWidth: limit.width, maxHeight: limit.height)
        }
        switch codec {
        case .hevc: return phys
        case .h264: return CodecLimits.clampForAvc(width: phys.0, height: phys.1)
        }
    }

    /// Returns physical pixel dimensions for a display ID.
    /// CGDisplayPixelsWide/High return logical pixels on HiDPI displays — use
    /// CGDisplayModeGetPixelWidth/Height to always get the true physical size.
    static func physicalSize(for displayID: CGDirectDisplayID) -> (width: Int, height: Int) {
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            let w = mode.pixelWidth
            let h = mode.pixelHeight
            if w > 0 && h > 0 { return (w, h) }
        }
        // Mode lookup failed — falling back to logical pixels (may be stale on HiDPI display)
        debugLog("physicalSize fallback for display \(displayID) — CGDisplayCopyDisplayMode returned nil")
        return (Int(CGDisplayPixelsWide(displayID)), Int(CGDisplayPixelsHigh(displayID)))
    }

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
        await MainActor.run { registerWakeObservers() }
    }

    // MARK: - Display wake handling

    /// Display sleep tears down SCStream (SCStreamErrorDomain -3815, "no
    /// displays or windows to capture"), which silently drops capture onto
    /// the CGDisplayStream fallback for the rest of the session. Restart
    /// the capture whenever the screens wake so it returns to SCStream.
    private func registerWakeObservers() {
        guard wakeObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.handleWake()
            }
            wakeObservers.append(token)
        }
        debugLog("Wake observers registered")
    }

    private func unregisterWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        wakeObservers.forEach { center.removeObserver($0) }
        wakeObservers.removeAll()
    }

    deinit {
        // Defensive: stopStreaming() already unregisters, but make sure a
        // dropped instance never leaves observer tokens behind.
        unregisterWakeObservers()
    }

    private func handleWake() {
        // Only act while a capture is actually running.
        guard stream != nil || cgDisplayStream != nil else { return }
        // A full system wake fires both screensDidWake and didWake —
        // coalesce them into a single restart.
        guard !wakeRestartPending else { return }
        wakeRestartPending = true
        debugLog("Screens woke — scheduling capture restart")
        // Give WindowServer a moment to settle before touching the stream.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.wakeRestartPending = false
            guard self.stream != nil || self.cgDisplayStream != nil else { return }
            // Display sleep usually kills SCStream with error -3815 ("no
            // displays or windows to capture"), which pushes capture onto the
            // CGDisplayStream fallback. After wake, always try to get back
            // onto SCStream — restartStream() re-enters the fallback by
            // itself if SCStream still cannot start.
            let fallbackActive = self.stateLock.withLock { $0.fallbackActive }
            if fallbackActive {
                debugLog("Wake restart: leaving CGDisplayStream fallback, retrying SCStream")
                self.cgDisplayStream?.stop()
                self.cgDisplayStream = nil
                self.stateLock.withLock { $0.fallbackActive = false }
            }
            self.restartStream()
            // A wake-triggered restart must not consume the one-shot budget
            // the frame monitor uses for stall recovery.
            self.restartAttempted = false
        }
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
        guard let display = display, virtualDisplayID != nil else {
            throw NSError(domain: "ScreenCapture", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Display not initialized"])
        }

        // Physical pixels for full Retina sharpness, clamped when H.264 (SCStream scales)
        let (width, height) = encodeSize(for: codec)
        let fps = refreshRate

        streamOutput = StreamOutput()

        let delegate = StreamDelegate()
        delegate.onStreamError = { [weak self] _ in
            guard let self = self else { return }
            debugLog("StreamDelegate error callback — attempting fallback")
            let alreadyActive = self.stateLock.withLock { $0.fallbackActive }
            if !alreadyActive {
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

    // MARK: - Shared frame handler (used by both startStreaming and restartStream)

    private func configureFrameHandler(label: String) {
        let queue = DispatchQueue(label: "encodeQueue.\(label)", qos: .userInteractive)
        encodeQueue = queue
        pendingEncodes = 0
        lastPixelBuffer = nil

        streamOutput?.onFrameReceived = { [weak self] sampleBuffer in
            guard let self = self else { return }

            // Thread-safe update of frame monitor state
            let isFirst = self.stateLock.withLock { state -> Bool in
                state.lastFrameTime = DispatchTime.now()
                if !state.hasReceivedFirstFrame {
                    state.hasReceivedFirstFrame = true
                    return true
                }
                return false
            }

            if isFirst {
                debugLog("First frame received from SCStream (\(label))")
                self.onCaptureMethodChanged?("SCStream")
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            // Backpressure: skip if encode queue already has 2+ frames pending
            let pending = OSAtomicAdd32(0, &self.pendingEncodes)
            if pending >= 2 {
                return
            }

            if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                self.lastPixelBuffer = imageBuffer
                OSAtomicIncrement32(&self.pendingEncodes)
                queue.async {
                    self.encoder?.encode(pixelBuffer: imageBuffer, presentationTimeStamp: pts)
                    OSAtomicDecrement32(&self.pendingEncodes)
                }
            } else if let cached = self.lastPixelBuffer {
                OSAtomicIncrement32(&self.pendingEncodes)
                queue.async {
                    self.encoder?.encode(pixelBuffer: cached, presentationTimeStamp: pts)
                    OSAtomicDecrement32(&self.pendingEncodes)
                }
            }
        }
    }

    // MARK: - Start streaming

    func startStreaming(to server: StreamingServer?, bitrateMbps: Int = 20, quality: String = "medium", gamingBoost: Bool = false, frameRate: Int = 60) {
        // Save parameters for potential restart
        currentServer = server
        currentBitrateMbps = bitrateMbps
        currentQuality = quality
        currentGamingBoost = gamingBoost
        currentFrameRate = frameRate

        isStreaming = true

        // Keep the display awake for the whole streaming session so the virtual
        // display never idle-sleeps (the sleep/wake cycle is what strands the
        // cursor — see the wake handling above for the residual cases).
        createDisplaySleepAssertion()

        let (width, height) = encodeSize(for: codec)

        encoder = VideoEncoder(width: width, height: height, codec: codec, bitrateMbps: bitrateMbps, quality: quality, gamingBoost: gamingBoost, frameRate: frameRate)
        encoder?.onEncodedFrame = { [weak server] data, timestamp, isKeyframe in
            server?.sendFrame(data, timestamp: timestamp, isKeyframe: isKeyframe)
        }

        // Apply any keyframe request that arrived before the encoder existed
        let shouldForceInitialKeyframe = keyframeRequestLock.withLock { state -> Bool in
            guard state.pendingEncoderCreationRequest else { return false }
            state.pendingEncoderCreationRequest = false
            return true
        }
        if shouldForceInitialKeyframe {
            encoder?.requestKeyframe()
        }

        // Reset frame monitor state
        stateLock.withLock { state in
            state.lastFrameTime = nil
            state.hasReceivedFirstFrame = false
        }

        configureFrameHandler(label: "initial")

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
            guard let self = self else { return }

            let isFallback = self.stateLock.withLock { $0.fallbackActive }
            guard !isFallback else {
                self.stopFrameMonitor()
                return
            }

            let stalled: Bool
            let lastTime = self.stateLock.withLock { $0.lastFrameTime }
            if let last = lastTime {
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
                let hasHadFrames = self.stateLock.withLock { $0.hasReceivedFirstFrame }

                if hasHadFrames, let lastBuffer = self.lastPixelBuffer {
                    // Screen is idle — SCStream is healthy but not delivering frames (macOS optimization).
                    // Re-send the last captured frame as a keepalive so the tablet stays connected.
                    let pts = CMTime(
                        value: CMTimeValue(DispatchTime.now().uptimeNanoseconds / 1000),
                        timescale: 1_000_000
                    )
                    self.encodeQueue?.async {
                        self.encoder?.encode(pixelBuffer: lastBuffer, presentationTimeStamp: pts)
                    }
                    self.stateLock.withLock { $0.lastFrameTime = DispatchTime.now() }
                    // Keep monitoring — real errors are handled by the SCStream error delegate
                } else {
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
        guard isStreaming else {
            debugLog("restartStream skipped — not streaming")
            return
        }

        streamGeneration &+= 1
        let gen = streamGeneration
        restartAttempted = true
        stateLock.withLock { $0.hasReceivedFirstFrame = false }

        Task {
            do {
                // Stop existing stream
                try? await stream?.stopCapture()
                // A stopStreaming() or a newer restart superseded this one — do
                // NOT bring capture back up (would resurrect a stopped stream).
                guard isStreaming, gen == streamGeneration else {
                    debugLog("restartStream(gen \(gen)) superseded after stopCapture — aborting")
                    return
                }

                stream = nil
                streamOutput = nil
                streamDelegate = nil
                display = nil

                // Re-setup
                try await setupDisplay()
                try await setupStream()
                guard isStreaming, gen == streamGeneration else {
                    debugLog("restartStream(gen \(gen)) superseded during setup — aborting")
                    try? await stream?.stopCapture()
                    stream = nil
                    return
                }

                // Re-attach encoding pipeline using shared handler
                configureFrameHandler(label: "restart")
                guard isStreaming, gen == streamGeneration else {
                    debugLog("restartStream(gen \(gen)) superseded before start — aborting")
                    return
                }

                try await stream?.startCapture()
                guard isStreaming, gen == streamGeneration else {
                    debugLog("restartStream(gen \(gen)) superseded after startCapture — aborting")
                    try? await stream?.stopCapture()
                    return
                }

                debugLog("SCStream restarted — starting frame flow monitor")
                startFrameMonitor()
            } catch {
                debugLog("SCStream restart failed: \(error) — falling back to CGDisplayStream")
                if isStreaming, gen == streamGeneration {
                    attemptFallbackCapture()
                } else {
                    debugLog("restartStream(gen \(gen)) superseded before fallback — aborted")
                }
            }
        }
    }

    // MARK: - Display-sleep assertion

    /// Keep the display awake while streaming. The captured surface is a
    /// virtual display; when the physical display idle-sleeps (pmset
    /// displaysleep), the virtual display stops producing frames and the
    /// cursor overlay is lost on wake. Holding
    /// kIOPMAssertionTypePreventUserIdleDisplaySleep avoids the whole
    /// sleep/wake transition; the wake observers above cover what it cannot
    /// (manual/forced sleep, lid close, display reconnects). Released in
    /// stopStreaming.
    private func createDisplaySleepAssertion() {
        guard !hasDisplaySleepAssertion else { return }
        let reason = "Side Screen is streaming to an external tablet display" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &displaySleepAssertionID)
        if result == kIOReturnSuccess {
            hasDisplaySleepAssertion = true
            debugLog("Display-sleep assertion held — display stays awake while streaming")
        } else {
            debugLog("Failed to create display-sleep assertion: IOReturn \(result)")
        }
    }

    private func releaseDisplaySleepAssertion() {
        guard hasDisplaySleepAssertion else { return }
        let result = IOPMAssertionRelease(displaySleepAssertionID)
        if result != kIOReturnSuccess {
            debugLog("IOPMAssertionRelease failed: IOReturn \(result)")
        }
        hasDisplaySleepAssertion = false
        displaySleepAssertionID = IOPMAssertionID(0)
        debugLog("Display-sleep assertion released")
    }

    // MARK: - CGDisplayStream fallback

    private func attemptFallbackCapture() {
        guard let displayID = virtualDisplayID else {
            debugLog("Fallback skipped — no displayID")
            return
        }

        // Thread-safe check-and-set for fallbackActive
        let alreadyActive = stateLock.withLock { state -> Bool in
            if state.fallbackActive { return true }
            state.fallbackActive = true
            return false
        }
        guard !alreadyActive else {
            debugLog("Fallback skipped — already active")
            return
        }

        // Stop SCStream synchronously (nil out output first to prevent new frames)
        streamOutput?.onFrameReceived = nil
        Task {
            try? await stream?.stopCapture()
            stream = nil
            streamOutput = nil
            streamDelegate = nil
        }

        // CGDisplayStream scales natively via outputWidth/Height, so the
        // AVC clamp applies here exactly as in the SCStream path.
        let (width, height) = encodeSize(for: codec)

        debugLog("CGDisplayStream fallback — display \(displayID) (\(width)x\(height))")

        let pixelFormat = Int32(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        let queue = DispatchQueue(label: "com.sidescreen.cgdisplaystream", qos: .userInteractive)

        // Without kCGDisplayStreamShowCursor the fallback stream never
        // composites the cursor at all (the key defaults to false), so any
        // session that degrades to CGDisplayStream loses the pointer on the
        // tablet even when WindowServer is healthy.
        let streamProps = [CGDisplayStream.showCursor as String: true] as CFDictionary

        guard let displayStream = CGDisplayStream(
            dispatchQueueDisplay: displayID,
            outputWidth: width,
            outputHeight: height,
            pixelFormat: pixelFormat,
            properties: streamProps,
            queue: queue,
            handler: { [weak self] _, _, frameSurface, _ in
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

                // Use CMClock for accurate timestamps instead of raw Mach time
                let pts = CMClockGetTime(CMClockGetHostTimeClock())
                self.encoder?.encode(pixelBuffer: pb, presentationTimeStamp: pts)
            }
        ) else {
            debugLog("Failed to create CGDisplayStream — fallback unavailable")
            stateLock.withLock { $0.fallbackActive = false }
            return
        }

        let startResult = displayStream.start()
        if startResult == .success {
            cgDisplayStream = displayStream
            debugLog("CGDisplayStream fallback started successfully")
            onCaptureMethodChanged?("CGDisplayStream (fallback)")
        } else {
            debugLog("CGDisplayStream.start() failed: \(startResult)")
            stateLock.withLock { $0.fallbackActive = false }
        }
    }

    // MARK: - Settings update

    func updateEncoderSettings(bitrateMbps: Int, quality: String, gamingBoost: Bool) {
        encoder?.updateSettings(bitrateMbps: bitrateMbps, quality: quality, gamingBoost: gamingBoost)
    }

    /// Switch the wire codec. No-op when unchanged. When changed mid-stream,
    /// rebuilds the encoder at the codec's encode size and restarts capture so
    /// SCStream delivers buffers at the (possibly clamped) dimensions. The
    /// client's keyframe-request loop (force, 200 ms interval) bridges the
    /// restart gap — the decoder drops frames until the first new keyframe.
    /// Note: if the CGDisplayStream fallback is active, restartStream() only
    /// rebuilds the SCStream path; the rare fallback+codec-switch combination
    /// recovers on the next fallback restart rather than immediately.
    /// Apply the per-connection negotiation result: stream codec plus the
    /// client's reported decoder ceiling. Rebuilds the encoder mid-session
    /// when either changes the encode setup (a codec switch, or a ceiling
    /// that alters the encode dimensions — issue #41).
    func negotiate(codec newCodec: StreamCodec, clientLimit: (width: Int, height: Int)?) {
        let sizeBefore = encodeSize(for: codec)
        let codecChanged = newCodec != codec
        if codecChanged {
            debugLog("Switching stream codec: \(codec) -> \(newCodec)")
        }
        codec = newCodec
        clientDecodeLimit = clientLimit

        guard encoder != nil else { return }  // not streaming yet; startStreaming will pick both up

        let sizeAfter = encodeSize(for: newCodec)
        guard codecChanged || sizeBefore != sizeAfter else { return }
        if sizeBefore != sizeAfter {
            let limitDesc = clientLimit.map { "\($0.width)x\($0.height)" } ?? "none"
            debugLog("Encode size \(sizeBefore.width)x\(sizeBefore.height) -> \(sizeAfter.width)x\(sizeAfter.height) (client decoder limit: \(limitDesc))")
        }
        rebuildEncoder()
    }

    private func rebuildEncoder() {
        let (width, height) = encodeSize(for: codec)
        let server = currentServer
        let newEncoder = VideoEncoder(width: width, height: height, codec: codec, bitrateMbps: currentBitrateMbps, quality: currentQuality, gamingBoost: currentGamingBoost, frameRate: currentFrameRate)
        newEncoder.onEncodedFrame = { [weak server] data, timestamp, isKeyframe in
            server?.sendFrame(data, timestamp: timestamp, isKeyframe: isKeyframe)
        }
        newEncoder.requestKeyframe()
        encoder = newEncoder

        restartStream()
    }

    // MARK: - Stop streaming

    func stopStreaming() {
        // Invalidate any in-flight restart (incl. the delayed wake restart) so
        // it cannot resurrect capture after this stop.
        isStreaming = false
        streamGeneration &+= 1

        // Cancel frame flow monitor
        stopFrameMonitor()

        // Let the display idle-sleep normally again once we stop streaming.
        releaseDisplaySleepAssertion()

        // Stop SCStream
        Task {
            do {
                try await stream?.stopCapture()
            } catch {
                debugLog("Failed to stop SCStream capture: \(error)")
            }
        }

        // Stop CGDisplayStream fallback
        let wasFallback = stateLock.withLock { $0.fallbackActive }
        if wasFallback {
            cgDisplayStream?.stop()
            cgDisplayStream = nil
            debugLog("CGDisplayStream fallback stopped")
        }

        // Reset state
        stateLock.withLock { state in
            state.lastFrameTime = nil
            state.hasReceivedFirstFrame = false
            state.fallbackActive = false
        }
        restartAttempted = false
        unregisterWakeObservers()
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
