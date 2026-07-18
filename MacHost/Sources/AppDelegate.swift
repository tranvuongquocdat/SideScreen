import Cocoa
import SwiftUI
import Combine
import ApplicationServices
import os.log
@preconcurrency import ScreenCaptureKit

// Debug file logger - writes to /tmp/sidescreen.log
func debugLog(_ message: String) {
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(timestamp)] \(message)\n"
    print(message)
    if let data = line.data(using: .utf8) {
        let url = URL(fileURLWithPath: "/tmp/sidescreen.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - Gesture State Machine

enum GestureState {
    case idle
    case pending          // Touch down, waiting to determine gesture
    case scrolling        // 1-finger scroll
    case longPressReady   // Long press detected, waiting for drag or release
    case dragging         // Long press + drag (left mouse drag)
    case twoFingerScroll  // 2-finger scroll
    case pinching         // Pinch zoom
    case multiFingerSwipe // 3/4-finger system gestures
}

private enum TouchAction {
    static let down = 0
    static let move = 1
    static let up = 2
    static let hover = 3
    static let hoverExit = 4
}

private enum TouchFlags {
    static let stylus = 1
    static let hover = 1 << 1
}

struct GestureThresholds {
    static let tapMaxDistance: CGFloat = 15
    static let tapMaxTime: UInt64 = 250_000_000       // 250ms
    static let doubleTapMaxTime: UInt64 = 400_000_000  // 400ms
    static let doubleTapMaxDistance: CGFloat = 20
    static let longPressTime: UInt64 = 500_000_000     // 500ms
    static let scrollSensitivity: CGFloat = 1.2
    static let pinchMinDistance: CGFloat = 28
    static let pinchDominanceRatio: CGFloat = 1.15
    static let scrollToPinchMinDistance: CGFloat = 48
    static let scrollToPinchDominanceRatio: CGFloat = 1.8
    static let pinchShortcutStepDistance: CGFloat = 55
    static let pinchShortcutInterval: UInt64 = 90_000_000 // ~11Hz
    static let pinchDirectionResetDistance: CGFloat = 24
    static let minScrollDelta: CGFloat = 0.5
    static let minPinchDelta: CGFloat = 1.0
    static let multiFingerSwipeMinDistance: CGFloat = 70
    static let multiFingerDirectionRatio: CGFloat = 1.25
    static let minTouchInterval: UInt64 = 8_000_000    // ~120Hz
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var streamingServer: StreamingServer?
    var screenCapture: ScreenCapture?
    var virtualDisplayManager: VirtualDisplayManager?
    var settings = DisplaySettings()
    var settingsWindow: SettingsWindowController?
    var statusItem: NSStatusItem?
    let pairedDeviceStore = PairedDeviceStore()
    /// Name of the wireless device currently streaming (nil when no wireless client is active).
    /// Used to roll its `lastConnected` timestamp forward every status refresh tick so the UI
    /// shows "just now" while connected and freezes at the disconnect moment afterward.
    private var currentWirelessDevice: String?
    private var cancellables = Set<AnyCancellable>()
    private var permissionCheckTimer: Timer?
    private var statusRefreshTimer: Timer?
    var isDaemonMode = false // Deprecated: keeping variable for ABI compatibility but unused

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("✅ App launched")

        // Create menu bar item
        setupMenuBar()

        // Setup settings window
        setupSettingsWindow()

        // Setup settings observers
        setupSettingsObservers()

        // Check permissions
        Task {
            await checkPermissions()
        }

        // Periodic status refresh for the per-mode checklist (ADB / WiFi / Listening IP).
        statusRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatusIndicators()
            }
        }
        // Initial refresh so the UI isn't blank for 2 seconds.
        Task { @MainActor in
            refreshStatusIndicators()
        }

        if #available(macOS 13.0, *) {
            if DaemonManager.shared.isEnabled {
                print("🚀 Launch at Login is enabled - starting silently in background")
                // Do not show settings window automatically.
                // applicationShouldHandleReopen will show it if the user manually launched the app.
            } else {
                showSettings()
            }
        } else {
            showSettings()
        }

        // Declarative auto-start (no Mac interaction): start the server in the
        // chosen Startup mode if enabled. No blocking permission modal here —
        // it cannot be acted on when the Mac is headless.
        if settings.autoStartStreamingOnLaunch {
            settings.connectionMode = settings.startupMode
            Task {
                await self.checkPermissions()
                if self.settings.hasScreenRecordingPermission {
                    await self.startServer()
                } else {
                    debugLog("Auto-start skipped: Screen Recording permission not granted")
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showSettings()
        }
        return true
    }

    @MainActor
    private func refreshStatusIndicators() {
        settings.adbInstalled = StatusDetector.adbInstalled()
        settings.wifiConnected = StatusDetector.wifiReachable()
        settings.listeningAddress = LANAddressResolver.primaryIPv4()
        settings.hasAccessibilityPermission = AXIsProcessTrusted()

        // While a wireless client is actively streaming, keep its lastConnected
        // rolling forward so the UI shows "just now". On disconnect, the
        // onClientDisconnected handler clears currentWirelessDevice — from that
        // point lastConnected stays frozen at the disconnect moment, so the
        // "X minutes ago" label counts up correctly.
        if let name = currentWirelessDevice {
            pairedDeviceStore.upsert(name: name, lastConnected: Date())
        }

        let port = Int(settings.port)
        Task.detached { [weak self] in
            let devices = StatusDetector.usbDevices()
            let reverseOK = StatusDetector.adbReverseConfigured(port: port)
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                
                let isConnected = !devices.isEmpty

                self.settings.usbDeviceConnected = isConnected
                self.settings.adbReverseConfigured = reverseOK

                // Self-healing USB bridge (level-triggered, not edge-triggered):
                // whenever we are in USB mode with the server running and a
                // device present but adb reverse missing, (re)establish it.
                // Covers replug, adb-server restart, etc. The server lifecycle
                // is NOT tied to device events — it stays up and the tablet
                // reconnects via its own connect button.
                if self.settings.connectionMode == .usb
                    && isConnected
                    && self.settings.isRunning
                    && !reverseOK {
                    debugLog("🔌 USB bridge missing while running — (re)establishing adb reverse")
                    Task { await self.setupADBReverse() }
                }
            }
        }
    }

    @MainActor
    private func handleConnectionModeChange(to mode: ConnectionMode) async {
        debugLog("Connection mode changed to: \(mode.rawValue)")
        // Disconnect any active client immediately (per spec §6 / fix #2).
        let wasRunning = settings.isRunning
        if wasRunning {
            stopServer()
        }
        if mode == .wireless {
            // Generate token if missing; the QR will reflect it.
            _ = WirelessAuth.loadOrCreate()
        }
        if wasRunning {
            await startServer()
        }
    }

    /// Check permissions on demand (called when settings window opens or manually)
    func refreshPermissions() {
        Task {
            await checkPermissions()
        }
    }

    func setupSettingsObservers() {
        // Observer cho gaming boost changes
        settings.$gamingBoost
            .dropFirst() // Skip initial value
            .sink { [weak self] gamingBoost in
                guard let self = self, self.settings.isRunning else { return }
                print("🎮 Gaming Boost \(gamingBoost ? "ENABLED" : "DISABLED")")
                self.screenCapture?.updateEncoderSettings(
                    bitrateMbps: self.settings.effectiveBitrate,
                    quality: self.settings.effectiveQuality,
                    gamingBoost: gamingBoost
                )
            }
            .store(in: &cancellables)

        // Observer cho bitrate/quality changes (chỉ khi không gaming boost)
        Publishers.CombineLatest(settings.$bitrate, settings.$quality)
            .dropFirst()
            .sink { [weak self] bitrate, quality in
                guard let self = self, self.settings.isRunning, !self.settings.gamingBoost else { return }
                print("⚙️ Settings updated: \(bitrate)Mbps, \(quality)")
                self.screenCapture?.updateEncoderSettings(
                    bitrateMbps: bitrate,
                    quality: quality,
                    gamingBoost: false
                )
            }
            .store(in: &cancellables)

        // Observer cho rotation changes - send to connected client immediately
        settings.$rotation
            .dropFirst()
            .sink { [weak self] rotation in
                guard let self = self, self.settings.isRunning else { return }
                print("🔄 Rotation changed to \(rotation)°")
                self.streamingServer?.updateRotation(rotation)
            }
            .store(in: &cancellables)

        // Observer cho touch enable/disable - propagate to streaming server so
        // incoming touch frames from the client are dropped early when off.
        settings.$touchEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                self?.streamingServer?.touchEnabled = enabled
            }
            .store(in: &cancellables)

        // Observer cho connection mode changes — restart server with new auth/ADB policy.
        settings.$connectionMode
            .dropFirst()
            .sink { [weak self] mode in
                guard let self = self else { return }
                Task { @MainActor in
                    await self.handleConnectionModeChange(to: mode)
                }
            }
            .store(in: &cancellables)

        // Observer cho resolution changes — the virtual display is created at
        // server start, so a new resolution (list row or custom Apply) needs a
        // stop/start cycle to take effect, same as a connection-mode change.
        // Without this, changing resolution mid-run silently did nothing.
        settings.$resolution
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] resolution in
                guard let self = self else { return }
                Task { @MainActor in
                    guard self.settings.isRunning else { return }
                    debugLog("Resolution changed to \(resolution) — restarting server to rebuild virtual display")
                    self.stopServer()
                    await self.startServer()
                }
            }
            .store(in: &cancellables)
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Virtual Display")
        }

        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Settings", action: #selector(showSettings), keyEquivalent: "s"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    func setupSettingsWindow() {
        settingsWindow = SettingsWindowController(settings: settings)

        settings.onToggleServer = { [weak self] in
            guard let self else { return }
            if self.settings.isRunning {
                self.stopServer()
            } else {
                Task { [weak self] in
                    await self?.startServer()
                }
            }
        }
    }

    @objc func showSettings() {
        settingsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func checkPermissions() async {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        debugLog("checkPermissions — macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")

        // Check Screen Recording permission using CoreGraphics API
        let hasScreenCapture = CGPreflightScreenCaptureAccess()
        await MainActor.run {
            settings.hasScreenRecordingPermission = hasScreenCapture
        }
        if hasScreenCapture {
            debugLog("Screen recording permission granted (CGPreflight)")

            // On macOS 26+, also verify ScreenCaptureKit is actually functional
            if version.majorVersion >= 26 {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    debugLog("SCShareableContent verification OK — \(content.displays.count) displays found")
                } catch {
                    debugLog("WARNING: CGPreflight OK but SCShareableContent failed on macOS 26: \(error.localizedDescription)")
                    debugLog("CGDisplayStream fallback will likely activate at capture time")
                }
            }
        } else {
            debugLog("Screen recording permission not granted yet")
            CGRequestScreenCaptureAccess()
        }

        // Check Accessibility permission (required for touch/mouse injection)
        await checkAccessibilityPermission()
    }

    func checkAccessibilityPermission() async {
        let trusted = AXIsProcessTrusted()
        await MainActor.run {
            settings.hasAccessibilityPermission = trusted
        }
        if trusted {
            print("✅ Accessibility permission granted")
        } else {
            print("⚠️  Accessibility permission not granted - touch control will not work")
        }
    }

    @MainActor
    func promptAccessibilityPermission() {
        // This will show the system prompt to grant Accessibility permission
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        settings.hasAccessibilityPermission = trusted

        if !trusted {
            print("⚠️  User needs to grant Accessibility permission in System Settings")
        }
    }

    /// Setup ADB reverse port forwarding for USB connection
    func setupADBReverse() async {
        let port = settings.port
        print("🔌 Setting up ADB reverse for port \(port)...")
        debugLog("🔌 setupADBReverse() invoked for port \(port)...")

        await Task.detached(priority: .utility) {
            // Try common adb paths
            let adbPaths = [
                "/usr/local/bin/adb",
                "/opt/homebrew/bin/adb",
                "~/Library/Android/sdk/platform-tools/adb",
                "/Users/\(NSUserName())/Library/Android/sdk/platform-tools/adb"
            ]

            var adbPath: String?
            for path in adbPaths {
                let expandedPath = NSString(string: path).expandingTildeInPath
                if FileManager.default.fileExists(atPath: expandedPath) {
                    adbPath = expandedPath
                    break
                }
            }

            // Also try 'which adb' to find it in PATH
            if adbPath == nil {
                let whichProcess = Process()
                whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
                whichProcess.arguments = ["adb"]
                let whichPipe = Pipe()
                whichProcess.standardOutput = whichPipe
                whichProcess.standardError = FileHandle.nullDevice

                do {
                    try whichProcess.run()
                    whichProcess.waitUntilExit()
                    let data = whichPipe.fileHandleForReading.readDataToEndOfFile()
                    if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !path.isEmpty {
                        adbPath = path
                    }
                } catch {
                    // Ignore
                }
            }

            guard let finalAdbPath = adbPath else {
                print("⚠️  ADB not found - USB connection may not work")
                print("💡 Install Android SDK or run manually: adb reverse tcp:\(port) tcp:\(port)")
                return
            }

            print("📱 Found ADB at: \(finalAdbPath)")

            // Retry adb reverse up to 3 times — handles first-install authorization delay
            for attempt in 1...3 {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: finalAdbPath)
                process.arguments = ["reverse", "tcp:\(port)", "tcp:\(port)"]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""

                    if process.terminationStatus == 0 {
                        print("✅ ADB reverse setup successful: tcp:\(port) -> tcp:\(port)")
                        return
                    } else {
                        print("⚠️  ADB reverse attempt \(attempt)/3 failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
                        if attempt < 3 {
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                        }
                    }
                } catch {
                    print("⚠️  Failed to run ADB (attempt \(attempt)/3): \(error.localizedDescription)")
                    if attempt < 3 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
            }

            print("💡 Make sure Android device is connected via USB with debugging enabled")
        }.value
    }

    @MainActor
    func showPermissionAlert() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let isMacOS26 = version.majorVersion >= 26

        let alert = NSAlert()
        if isMacOS26 {
            alert.messageText = "Screen & System Audio Recording Permission Required"
            alert.informativeText = "Please grant Screen & System Audio Recording permission in System Settings > Privacy & Security."
        } else {
            alert.messageText = "Screen Recording Permission Required"
            alert.informativeText = "Please grant Screen Recording permission in System Settings > Privacy & Security."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    func startServer() async {
        debugLog("🚀 startServer() invoked. Check permission: \(settings.hasScreenRecordingPermission)")
        guard settings.hasScreenRecordingPermission else {
            debugLog("❌ startServer aborted: Missing Screen Recording permission")
            await showPermissionAlert()
            return
        }

        do {
            // Create virtual display and run ADB setup in parallel
            virtualDisplayManager = VirtualDisplayManager()
            let size = settings.resolutionSize
            try virtualDisplayManager?.createDisplay(
                width: size.width,
                height: size.height,
                refreshRate: settings.refreshRate,
                hiDPI: settings.hiDPI,
                name: "SideScreen"
            )

            // Disable mirror mode (may fail if already in extend mode)
            do {
                try virtualDisplayManager?.disableMirrorMode()
            } catch {
                // Not critical - continue anyway
            }

            await MainActor.run {
                settings.displayCreated = true
            }

            // Run ADB setup (USB only) and display init wait in parallel.
            // For wireless mode, skip ADB entirely — the auth handshake gates LAN connections instead.
            await withTaskGroup(of: Void.self) { group in
                if settings.connectionMode == .usb {
                    group.addTask { await self.setupADBReverse() }
                } else {
                    debugLog("Wireless mode: skipping ADB setup")
                }
                group.addTask { try? await Task.sleep(nanoseconds: 500_000_000) }
            }

            virtualDisplayManager?.restoreDisplayPosition()

            // Verify display is registered in the system
            if let vdm = virtualDisplayManager {
                let registered = vdm.verifyDisplayRegistered()
                if !registered {
                    debugLog("WARNING: Virtual display not found in online display list — capture may fail")
                }
            }

            // Setup capture
            guard let displayID = virtualDisplayManager?.displayID else { return }
            screenCapture = try await ScreenCapture()
            screenCapture?.onCaptureMethodChanged = { [weak self] method in
                guard let self = self else { return }
                debugLog("Capture method: \(method)")
                Task { @MainActor in
                    self.settings.captureMethod = method
                }
            }
            try await screenCapture?.setupForVirtualDisplay(displayID, refreshRate: settings.effectiveRefreshRate)

            // Setup server
            streamingServer = StreamingServer(port: settings.port)
            streamingServer?.touchEnabled = settings.touchEnabled
            if settings.connectionMode == .wireless {
                streamingServer?.expectedAuthToken = WirelessAuth.loadOrCreate()
                streamingServer?.onWirelessClientPaired = { [weak self] deviceName in
                    guard let self = self else { return }
                    Task { @MainActor in
                        self.currentWirelessDevice = deviceName
                        self.settings.currentWirelessDevice = deviceName
                        self.pairedDeviceStore.upsert(name: deviceName, lastConnected: Date())
                    }
                }
            }
            // Send the LOGICAL resolution that the user picked. The H.264 SPS in
            // the stream still carries the true physical pixel dimensions, so the
            // Android decoder/MediaCodec sets up correctly regardless. Sending the
            // logical dimensions here makes the resolution overlay on Android
            // match the Mac's resolution dropdown (e.g. "2560x1600" instead of
            // the HiDPI-doubled "5120x3200").
            streamingServer?.setDisplaySize(width: size.width, height: size.height, rotation: settings.rotation)
            streamingServer?.onClientConnected = { [weak self] in
                guard let self = self else { return }
                self.screenCapture?.requestKeyframeOrReplayCachedFrame(force: true)
                Task { @MainActor in
                    self.settings.clientConnected = true
                }
            }
            // Runs synchronously on the server's network queue BEFORE the
            // display config is sent, so the config below carries the right
            // dimensions for the negotiated codec.
            streamingServer?.onCodecNegotiated = { [weak self] codec in
                guard let self = self, let capture = self.screenCapture else { return }
                capture.setCodec(codec)
                switch codec {
                case .hevc:
                    // Logical user-picked resolution, exactly as at startup.
                    self.streamingServer?.setDisplaySize(width: size.width, height: size.height, rotation: self.settings.rotation)
                case .h264:
                    // Clamped physical encode size: the client must configure
                    // its (weak) AVC decoder within its supported range, and
                    // this matches what the stream's SPS will carry.
                    let enc = capture.encodeSize(for: .h264)
                    self.streamingServer?.setDisplaySize(width: enc.width, height: enc.height, rotation: self.settings.rotation)
                }
            }
            streamingServer?.onKeyframeRequested = { [weak self] force in
                self?.screenCapture?.requestKeyframeOrReplayCachedFrame(force: force)
            }

            streamingServer?.onClientDisconnected = { [weak self] in
                guard let self = self else { return }
                Task { @MainActor in
                    self.settings.clientConnected = false
                    // Final lastConnected snapshot at the disconnect moment, then
                    // freeze (currentWirelessDevice = nil stops the rolling update
                    // in refreshStatusIndicators).
                    if let name = self.currentWirelessDevice {
                        self.pairedDeviceStore.upsert(name: name, lastConnected: Date())
                        self.currentWirelessDevice = nil
                        self.settings.currentWirelessDevice = nil
                    }
                }
            }

            streamingServer?.onTouchEvent = { [weak self] x, y, action, pointerCount, x2, y2, x3, y3, x4, y4, pressure, tilt, flags in
                self?.handleTouch(x: x, y: y, action: action, pointerCount: pointerCount, x2: x2, y2: y2, x3: x3, y3: y3, x4: x4, y4: y4, pressure: pressure, tilt: tilt, flags: flags)
            }

            streamingServer?.onStats = { [weak self] fps, mbps in
                let captured = self
                Task { @MainActor in
                    captured?.settings.currentFPS = fps
                    captured?.settings.currentBitrate = mbps
                }
            }

            streamingServer?.start()
            screenCapture?.startStreaming(
                to: streamingServer,
                bitrateMbps: settings.effectiveBitrate,
                quality: settings.effectiveQuality,
                gamingBoost: settings.gamingBoost,
                frameRate: settings.effectiveRefreshRate
            )

            await MainActor.run {
                settings.isRunning = true
            }

            print("✅ Server started on port \(settings.port)")
        } catch {
            print("❌ Failed to start: \(error)")
            await MainActor.run {
                settings.isRunning = false
                settings.displayCreated = false

                let alert = NSAlert()
                alert.messageText = "Failed to Start Server"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }

    func stopServer() {
        // Save display position before destroying
        virtualDisplayManager?.saveDisplayPosition()

        screenCapture?.stopStreaming()
        streamingServer?.stop()
        virtualDisplayManager?.destroyDisplay()

        settings.isRunning = false
        settings.displayCreated = false
        settings.clientConnected = false
        settings.currentFPS = 0
        settings.currentBitrate = 0

        print("⏹️ Server stopped")
    }

    // MARK: - Gesture Properties

    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private var accessibilityWarningShown = false
    private var gestureState: GestureState = .idle
    private var lastTouchTime: UInt64 = 0

    // Touch tracking
    private var touchStartPosition: CGPoint = .zero
    private var touchLastPosition: CGPoint = .zero
    private var touchStartTime: UInt64 = 0
    private var touchLastMoveTime: UInt64 = 0
    private var lastScrollDeltaX: CGFloat = 0
    private var lastScrollDeltaY: CGFloat = 0

    // Double tap tracking
    private var lastTapTime: UInt64 = 0
    private var lastTapPosition: CGPoint = .zero

    // Long press timer
    private var longPressTimer: DispatchWorkItem?

    // 2-finger tracking
    private var initialPinchDistance: CGFloat = 0
    private var lastPinchDistance: CGFloat = 0
    private var pinchShortcutRemainder: CGFloat = 0
    private var lastPinchShortcutTime: UInt64 = 0
    private var lastPinchDirection: Int = 0
    private var lastTwoFingerDebugTime: UInt64 = 0
    private var multiFingerStartPosition: CGPoint = .zero
    private var multiFingerLastPosition: CGPoint = .zero
    private var multiFingerCount = 0
    private var multiFingerGestureTriggered = false

    // Momentum scrolling
    private var momentumTimer: Timer?
    private var momentumVelocityX: CGFloat = 0
    private var momentumVelocityY: CGFloat = 0
    private var lastMomentumPosition: CGPoint = .zero

    // MARK: - Touch Entry Point

    func handleTouch(x: Float, y: Float, action: Int, pointerCount: Int = 1, x2: Float = 0, y2: Float = 0, x3: Float = 0, y3: Float = 0, x4: Float = 0, y4: Float = 0, pressure: Float = 0, tilt: Float = 0, flags: Int = 0) {
        guard settings.touchEnabled else { return }

        if !AXIsProcessTrusted() {
            if !accessibilityWarningShown {
                accessibilityWarningShown = true
                debugLog("Accessibility not granted - touch ignored")
                Task { @MainActor in
                    settings.hasAccessibilityPermission = false
                }
            }
            return
        }

        guard let displayID = virtualDisplayManager?.displayID else { return }
        let bounds = CGDisplayBounds(displayID)

        let p1 = CGPoint(
            x: bounds.origin.x + CGFloat(x) * bounds.width,
            y: bounds.origin.y + CGFloat(y) * bounds.height
        )
        let p2 = CGPoint(
            x: bounds.origin.x + CGFloat(x2) * bounds.width,
            y: bounds.origin.y + CGFloat(y2) * bounds.height
        )
        let p3 = CGPoint(
            x: bounds.origin.x + CGFloat(x3) * bounds.width,
            y: bounds.origin.y + CGFloat(y3) * bounds.height
        )
        let p4 = CGPoint(
            x: bounds.origin.x + CGFloat(x4) * bounds.width,
            y: bounds.origin.y + CGFloat(y4) * bounds.height
        )

        let isStylus = (flags & TouchFlags.stylus) != 0
        if isStylus {
            injectTabletEvent(at: p1, action: action, pressure: pressure, tilt: tilt)
        } else if pointerCount >= 3 {
            let points = pointerCount >= 4 ? [p1, p2, p3, p4] : [p1, p2, p3]
            handleMultiFingerTouch(points: points, action: action)
        } else if pointerCount >= 2 {
            handleTwoFingerTouch(p1: p1, p2: p2, action: action)
        } else {
            handleOneFingerTouch(at: p1, action: action)
        }
    }

    private func handleMultiFingerTouch(points: [CGPoint], action: Int) {
        guard let centroid = centroid(of: points) else { return }

        switch action {
        case TouchAction.down:
            cancelLongPressTimer()
            stopMomentumScroll()
            gestureState = .multiFingerSwipe
            multiFingerStartPosition = centroid
            multiFingerLastPosition = centroid
            multiFingerCount = points.count
            multiFingerGestureTriggered = false

        case TouchAction.move:
            if gestureState != .multiFingerSwipe || multiFingerCount != points.count {
                gestureState = .multiFingerSwipe
                multiFingerStartPosition = centroid
                multiFingerCount = points.count
                multiFingerGestureTriggered = false
            }

            guard !multiFingerGestureTriggered else {
                multiFingerLastPosition = centroid
                return
            }

            let dx = centroid.x - multiFingerStartPosition.x
            let dy = centroid.y - multiFingerStartPosition.y
            let distance = hypot(dx, dy)
            guard distance >= GestureThresholds.multiFingerSwipeMinDistance else {
                multiFingerLastPosition = centroid
                return
            }

            if abs(dx) > abs(dy) * GestureThresholds.multiFingerDirectionRatio {
                injectSystemGestureShortcut(keyCode: dx > 0 ? 124 : 123)
                multiFingerGestureTriggered = true
            } else if abs(dy) > abs(dx) * GestureThresholds.multiFingerDirectionRatio {
                injectSystemGestureShortcut(keyCode: dy > 0 ? 125 : 126)
                multiFingerGestureTriggered = true
            }
            multiFingerLastPosition = centroid

        case TouchAction.up:
            gestureState = .idle
            multiFingerGestureTriggered = false
            multiFingerCount = 0

        default:
            break
        }
    }

    private func centroid(of points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    // MARK: - 1-Finger Gesture State Machine

    private func handleOneFingerTouch(at point: CGPoint, action: Int) {
        switch action {
        case 0: oneFingerDown(at: point)
        case 1: oneFingerMove(to: point)
        case 2: oneFingerUp(at: point)
        default: break
        }
    }

    private func oneFingerDown(at point: CGPoint) {
        stopMomentumScroll()
        cancelLongPressTimer()

        touchStartPosition = point
        touchLastPosition = point
        touchStartTime = DispatchTime.now().uptimeNanoseconds
        touchLastMoveTime = touchStartTime
        gestureState = .pending

        // Move cursor to touch position (absolute)
        moveCursor(to: point)

        // Start long press timer
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.gestureState == .pending else { return }
            self.gestureState = .longPressReady
        }
        longPressTimer = timer
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .nanoseconds(Int(GestureThresholds.longPressTime)),
            execute: timer
        )
    }

    private func oneFingerMove(to point: CGPoint) {
        let now = DispatchTime.now().uptimeNanoseconds
        if now - lastTouchTime < GestureThresholds.minTouchInterval { return }
        lastTouchTime = now

        let deltaX = point.x - touchLastPosition.x
        let deltaY = point.y - touchLastPosition.y
        let totalDistance = hypot(point.x - touchStartPosition.x, point.y - touchStartPosition.y)

        switch gestureState {
        case .pending:
            if totalDistance > GestureThresholds.tapMaxDistance {
                cancelLongPressTimer()
                gestureState = .scrolling
                let sx = deltaX * GestureThresholds.scrollSensitivity
                let sy = deltaY * GestureThresholds.scrollSensitivity
                injectScrollEvent(deltaX: sx, deltaY: sy, at: point)
                lastScrollDeltaX = sx
                lastScrollDeltaY = sy
            }

        case .longPressReady:
            if totalDistance > GestureThresholds.tapMaxDistance {
                // Long press + drag → left mouse drag
                gestureState = .dragging
                injectMouseDown(at: touchStartPosition)
                injectMouseDragged(to: point)
            }

        case .scrolling:
            let sx = deltaX * GestureThresholds.scrollSensitivity
            let sy = deltaY * GestureThresholds.scrollSensitivity
            injectScrollEvent(deltaX: sx, deltaY: sy, at: point)
            let timeDelta = now - touchLastMoveTime
            if timeDelta > 0 && timeDelta < 100_000_000 {
                lastScrollDeltaX = sx
                lastScrollDeltaY = sy
            }

        case .dragging:
            injectMouseDragged(to: point)

        default:
            break
        }

        touchLastPosition = point
        touchLastMoveTime = now
    }

    private func oneFingerUp(at point: CGPoint) {
        cancelLongPressTimer()
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now - touchStartTime
        let distance = hypot(point.x - touchStartPosition.x, point.y - touchStartPosition.y)

        switch gestureState {
        case .pending:
            // Quick release, no movement → tap or double tap
            if distance < GestureThresholds.tapMaxDistance && elapsed < GestureThresholds.tapMaxTime {
                // Check double tap
                let timeSinceLastTap = now - lastTapTime
                let distFromLastTap = hypot(point.x - lastTapPosition.x, point.y - lastTapPosition.y)

                if timeSinceLastTap < GestureThresholds.doubleTapMaxTime
                    && distFromLastTap < GestureThresholds.doubleTapMaxDistance {
                    performDoubleClick(at: point)
                    lastTapTime = 0  // Reset so triple tap doesn't trigger
                } else {
                    performClick(at: point)
                    lastTapTime = now
                    lastTapPosition = point
                }
            }

        case .longPressReady:
            // Held long but didn't drag → right click
            performRightClick(at: point)

        case .scrolling:
            // Check momentum
            let timeSinceLastMove = now - touchLastMoveTime
            if timeSinceLastMove < 50_000_000 {
                let threshold: CGFloat = 2.0
                if abs(lastScrollDeltaX) > threshold || abs(lastScrollDeltaY) > threshold {
                    startMomentumScroll(
                        velocityX: lastScrollDeltaX * 6.0,
                        velocityY: lastScrollDeltaY * 6.0,
                        at: point
                    )
                }
            }

        case .dragging:
            injectMouseUp(at: point)

        default:
            break
        }

        gestureState = .idle
    }

    // MARK: - 2-Finger Gestures

    private func handleTwoFingerTouch(p1: CGPoint, p2: CGPoint, action: Int) {
        let distance = hypot(p2.x - p1.x, p2.y - p1.y)
        let midpoint = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)

        switch action {
        case 0: // Down
            cancelLongPressTimer()
            stopMomentumScroll()
            gestureState = .idle
            initialPinchDistance = distance
            lastPinchDistance = distance
            pinchShortcutRemainder = 0
            lastPinchShortcutTime = 0
            lastPinchDirection = 0
            touchStartPosition = midpoint
            touchLastPosition = midpoint

        case 1: // Move
            let now = DispatchTime.now().uptimeNanoseconds
            let rawDX = midpoint.x - touchLastPosition.x
            let rawDY = midpoint.y - touchLastPosition.y
            let totalPinchDelta = distance - initialPinchDistance
            let framePinchDelta = distance - lastPinchDistance
            let panDistance = hypot(midpoint.x - touchStartPosition.x, midpoint.y - touchStartPosition.y)
            let canPromoteScrollToPinch =
                gestureState == .twoFingerScroll &&
                abs(totalPinchDelta) >= GestureThresholds.scrollToPinchMinDistance &&
                abs(totalPinchDelta) > panDistance * GestureThresholds.scrollToPinchDominanceRatio
            let shouldPinch =
                gestureState == .pinching ||
                canPromoteScrollToPinch ||
                (
                    gestureState != .twoFingerScroll &&
                    abs(totalPinchDelta) >= GestureThresholds.pinchMinDistance &&
                    abs(totalPinchDelta) > panDistance * GestureThresholds.pinchDominanceRatio
                )
            let didScroll =
                !shouldPinch &&
                gestureState != .pinching &&
                (abs(rawDX) >= GestureThresholds.minScrollDelta || abs(rawDY) >= GestureThresholds.minScrollDelta)

            if didScroll {
                let phase: CGScrollPhase = gestureState == .idle ? .began : .changed
                let dx = rawDX * GestureThresholds.scrollSensitivity
                let dy = rawDY * GestureThresholds.scrollSensitivity
                injectScrollEvent(deltaX: dx, deltaY: dy, at: midpoint, phase: phase)
                lastScrollDeltaX = dx
                lastScrollDeltaY = dy
                if gestureState == .idle {
                    gestureState = .twoFingerScroll
                }
            }

            if shouldPinch && gestureState != .pinching {
                if gestureState == .twoFingerScroll {
                    injectScrollEvent(deltaX: 0, deltaY: 0, at: midpoint, phase: .ended)
                }
                gestureState = .pinching
                lastPinchDistance = distance
                pinchShortcutRemainder = 0
                lastPinchShortcutTime = 0
                lastPinchDirection = 0
                debugLog("Two-finger pinch began: initial=\(String(format: "%.1f", initialPinchDistance)) current=\(String(format: "%.1f", distance)) totalDelta=\(String(format: "%.1f", totalPinchDelta)) pan=\(String(format: "%.1f", panDistance)) promoted=\(canPromoteScrollToPinch)")
            }

            if gestureState == .pinching {
                emitDebouncedPinchZoom(frameDelta: framePinchDelta, now: now)
                lastPinchDistance = distance
            } else {
                logTwoFingerDebug(distance: distance, totalDelta: totalPinchDelta, rawDX: rawDX, rawDY: rawDY)
            }

            touchLastPosition = midpoint

        case 2: // Up
            if gestureState == .twoFingerScroll {
                injectScrollEvent(deltaX: 0, deltaY: 0, at: midpoint, phase: .ended)
            }
            debugLog("Two-finger ended: state=\(gestureState)")
            gestureState = .idle
            touchStartPosition = .zero
            touchLastPosition = .zero
            initialPinchDistance = 0
            lastPinchDistance = 0
            pinchShortcutRemainder = 0
            lastPinchShortcutTime = 0
            lastPinchDirection = 0

        default:
            break
        }
    }

    // MARK: - Event Injection

    private func moveCursor(to point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func logTwoFingerDebug(distance: CGFloat, totalDelta: CGFloat, rawDX: CGFloat, rawDY: CGFloat) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastTwoFingerDebugTime > 250_000_000 else { return }
        lastTwoFingerDebugTime = now
        debugLog(
            "Two-finger move: state=\(gestureState) distance=\(String(format: "%.1f", distance)) " +
            "totalDelta=\(String(format: "%.1f", totalDelta)) dx=\(String(format: "%.1f", rawDX)) dy=\(String(format: "%.1f", rawDY))"
        )
    }

    private func emitDebouncedPinchZoom(frameDelta: CGFloat, now: UInt64) {
        guard frameDelta != 0 else { return }

        let direction = frameDelta > 0 ? 1 : -1
        if lastPinchDirection != 0 && direction != lastPinchDirection {
            pinchShortcutRemainder += frameDelta
            if abs(pinchShortcutRemainder) < GestureThresholds.pinchDirectionResetDistance {
                return
            }
            pinchShortcutRemainder = frameDelta
        } else {
            pinchShortcutRemainder += frameDelta
        }

        guard abs(pinchShortcutRemainder) >= GestureThresholds.pinchShortcutStepDistance else { return }
        guard lastPinchShortcutTime == 0 || now - lastPinchShortcutTime >= GestureThresholds.pinchShortcutInterval else { return }

        let zoomIn = pinchShortcutRemainder > 0
        injectZoomShortcut(zoomIn: zoomIn)
        lastPinchShortcutTime = now
        lastPinchDirection = zoomIn ? 1 : -1
        pinchShortcutRemainder += zoomIn ? -GestureThresholds.pinchShortcutStepDistance : GestureThresholds.pinchShortcutStepDistance
        if abs(pinchShortcutRemainder) > GestureThresholds.pinchShortcutStepDistance {
            pinchShortcutRemainder = 0
        }
        debugLog("Two-finger pinch zoom: shortcut=\(zoomIn ? "in" : "out") frame=\(String(format: "%.2f", frameDelta)) remainder=\(String(format: "%.2f", pinchShortcutRemainder))")
    }

    private func injectTabletEvent(at point: CGPoint, action: Int, pressure: Float, tilt: Float) {
        let eventType: CGEventType
        switch action {
        case TouchAction.down:
            eventType = .leftMouseDown
        case TouchAction.move:
            eventType = .leftMouseDragged
        case TouchAction.up:
            eventType = .leftMouseUp
        case TouchAction.hover, TouchAction.hoverExit:
            eventType = .mouseMoved
        default:
            return
        }

        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: eventType,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return }

        event.setIntegerValueField(.mouseEventSubtype, value: Int64(NX_SUBTYPE_TABLET_POINT))
        event.setDoubleValueField(.tabletEventPointPressure, value: Double(pressure))
        event.setDoubleValueField(.tabletEventTiltX, value: Double(tilt))
        event.setDoubleValueField(.tabletEventTiltY, value: 0)
        event.post(tap: .cghidEventTap)
    }

    private func injectSystemGestureShortcut(keyCode: CGKeyCode) {
        guard
            let down = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false)
        else { return }

        down.flags = .maskControl
        up.flags = .maskControl
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func injectZoomShortcut(zoomIn: Bool) {
        let keyCode: CGKeyCode = zoomIn ? 24 : 27 // ANSI "=" and "-"
        guard
            let down = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func performClick(at point: CGPoint) {
        if let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            down.setIntegerValueField(.mouseEventClickState, value: 1)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            up.setIntegerValueField(.mouseEventClickState, value: 1)
            up.post(tap: .cghidEventTap)
        }
    }

    private func performDoubleClick(at point: CGPoint) {
        if let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            down.setIntegerValueField(.mouseEventClickState, value: 2)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            up.setIntegerValueField(.mouseEventClickState, value: 2)
            up.post(tap: .cghidEventTap)
        }
    }

    private func performRightClick(at point: CGPoint) {
        if let down = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right) {
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right) {
            up.post(tap: .cghidEventTap)
        }
    }

    private func injectMouseDown(at point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap)
        }
    }

    private func injectMouseDragged(to point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func injectMouseUp(at point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func injectScrollEvent(deltaX: CGFloat, deltaY: CGFloat, at position: CGPoint, phase: CGScrollPhase = .changed) {
        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        ) else { return }
        scrollEvent.location = position
        scrollEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        scrollEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        scrollEvent.post(tap: .cghidEventTap)
    }

    // MARK: - Long Press Timer

    private func cancelLongPressTimer() {
        longPressTimer?.cancel()
        longPressTimer = nil
    }

    // MARK: - Momentum Scrolling

    private func startMomentumScroll(velocityX: CGFloat, velocityY: CGFloat, at position: CGPoint) {
        stopMomentumScroll()
        momentumVelocityX = velocityX
        momentumVelocityY = velocityY
        lastMomentumPosition = position
        momentumTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.momentumTick()
        }
    }

    private func momentumTick() {
        let decay: CGFloat = 0.92
        let minVelocity: CGFloat = 0.5

        if abs(momentumVelocityX) < minVelocity && abs(momentumVelocityY) < minVelocity {
            stopMomentumScroll()
            return
        }

        injectScrollEvent(deltaX: momentumVelocityX, deltaY: momentumVelocityY, at: lastMomentumPosition)
        momentumVelocityX *= decay
        momentumVelocityY *= decay
    }

    private func stopMomentumScroll() {
        momentumTimer?.invalidate()
        momentumTimer = nil
        momentumVelocityX = 0
        momentumVelocityY = 0
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop momentum scrolling
        stopMomentumScroll()

        // Stop server and cleanup
        stopServer()

        // Cancel all combine subscriptions
        cancellables.removeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
