import Cocoa
import SwiftUI
import Combine
import ApplicationServices
import os.log

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

// MARK: - Simple Touch State (optimized to use nanoseconds instead of Date)
struct TouchState {
    var startPosition: CGPoint
    var lastPosition: CGPoint
    var startTime: UInt64  // nanoseconds
    var lastMoveTime: UInt64  // nanoseconds
    var isTap: Bool = true
    var lastDeltaX: CGFloat = 0
    var lastDeltaY: CGFloat = 0

    init(position: CGPoint) {
        let now = DispatchTime.now().uptimeNanoseconds
        self.startPosition = position
        self.lastPosition = position
        self.startTime = now
        self.lastMoveTime = now
    }
}

// MARK: - Simple Thresholds
struct GestureThresholds {
    static let tapMaxDistance: CGFloat = 15
    static let tapMaxTime: UInt64 = 250_000_000  // 250ms in nanoseconds
    static let scrollSensitivity: CGFloat = 1.2
    static let minTouchInterval: UInt64 = 8_000_000  // ~120Hz throttle (8ms in nanoseconds)
}

@available(macOS 14.0, *)
class AppDelegate: NSObject, NSApplicationDelegate {
    var streamingServer: StreamingServer?
    var screenCapture: ScreenCapture?
    var virtualDisplayManager: VirtualDisplayManager?
    var settings = DisplaySettings()
    var settingsWindow: SettingsWindowController?
    var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var permissionCheckTimer: Timer?

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

        // Show settings window
        showSettings()
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
        // Check Screen Recording permission using CoreGraphics API
        let hasScreenCapture = CGPreflightScreenCaptureAccess()
        await MainActor.run {
            settings.hasScreenRecordingPermission = hasScreenCapture
        }
        if hasScreenCapture {
            print("✅ Screen recording permission granted")
        } else {
            print("⚠️  Screen recording permission not granted yet")
            // Prompt user to grant permission
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
    func setupADBReverse() {
        let port = settings.port
        print("🔌 Setting up ADB reverse for port \(port)...")

        // Run adb reverse in background
        DispatchQueue.global(qos: .utility).async {
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

            // Run adb reverse
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
                } else {
                    print("⚠️  ADB reverse failed: \(output)")
                    print("💡 Make sure Android device is connected via USB with debugging enabled")
                }
            } catch {
                print("⚠️  Failed to run ADB: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "Please grant Screen Recording permission in System Settings > Privacy & Security."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    func startServer() async {
        guard settings.hasScreenRecordingPermission else {
            await showPermissionAlert()
            return
        }

        setupADBReverse()

        do {
            // Create virtual display
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

            // Wait for display to initialize
            try await Task.sleep(nanoseconds: 500_000_000)

            virtualDisplayManager?.restoreDisplayPosition()

            // Setup capture
            guard let displayID = virtualDisplayManager?.displayID else { return }
            screenCapture = try await ScreenCapture()
            try await screenCapture?.setupForVirtualDisplay(displayID, refreshRate: settings.effectiveRefreshRate)

            // Setup server
            streamingServer = StreamingServer(port: settings.port)
            streamingServer?.setDisplaySize(width: size.width, height: size.height, rotation: settings.rotation)
            streamingServer?.onClientConnected = { [weak self] in
                let captured = self
                captured?.screenCapture?.requestKeyframe()
                Task { @MainActor in
                    captured?.settings.clientConnected = true
                }
            }

            streamingServer?.onTouchEvent = { [weak self] x, y, action in
                self?.handleTouch(x: x, y: y, action: action)
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

    private var lastMousePosition: CGPoint = .zero
    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private var accessibilityWarningShown = false
    private var touchState: TouchState?
    private var lastTouchTime: UInt64 = 0  // For throttling

    // Momentum scrolling - use CVDisplayLink for smoother animation
    private var momentumTimer: Timer?
    private var momentumVelocityX: CGFloat = 0
    private var momentumVelocityY: CGFloat = 0
    private var lastMomentumPosition: CGPoint = .zero

    func handleTouch(x: Float, y: Float, action: Int) {
        // Check Accessibility permission before injecting events
        if !AXIsProcessTrusted() {
            if !accessibilityWarningShown {
                accessibilityWarningShown = true
                print("⚠️  Accessibility permission not granted - touch events will be ignored")
                print("💡 Grant permission in System Settings > Privacy & Security > Accessibility")
                Task { @MainActor in
                    settings.hasAccessibilityPermission = false
                }
            }
            return
        }

        guard let displayID = virtualDisplayManager?.displayID else {
            print("❌ handleTouch: displayID is nil")
            return
        }

        let bounds = CGDisplayBounds(displayID)

        // Calculate absolute position on the virtual display
        let absoluteX = bounds.origin.x + (CGFloat(x) * bounds.width)
        let absoluteY = bounds.origin.y + (CGFloat(y) * bounds.height)
        let point = CGPoint(x: absoluteX, y: absoluteY)

        switch action {
        case 0: handleTouchDown(at: point)
        case 1: handleTouchMove(to: point)
        case 2: handleTouchUp(at: point)
        default: break
        }
    }

    // MARK: - Simple Gesture Handling

    private func handleTouchDown(at point: CGPoint) {
        // Stop any ongoing momentum scroll
        stopMomentumScroll()

        // Initialize touch state - assume tap until proven otherwise
        touchState = TouchState(position: point)
        lastMousePosition = point

        // Move cursor to position
        if let moveEvent = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
        }
    }

    private func handleTouchMove(to point: CGPoint) {
        guard var state = touchState else { return }

        let now = DispatchTime.now().uptimeNanoseconds

        // Throttle touch move events to ~120Hz max
        if now - lastTouchTime < GestureThresholds.minTouchInterval {
            return
        }
        lastTouchTime = now

        let deltaX = point.x - state.lastPosition.x
        let deltaY = point.y - state.lastPosition.y
        let totalDistance = hypot(point.x - state.startPosition.x, point.y - state.startPosition.y)

        // Check if movement exceeds tap threshold
        if totalDistance > GestureThresholds.tapMaxDistance {
            state.isTap = false
        }

        // If not a tap anymore, treat as scroll
        if !state.isTap {
            let scrollDeltaX = deltaX * GestureThresholds.scrollSensitivity
            let scrollDeltaY = deltaY * GestureThresholds.scrollSensitivity

            injectScrollEvent(deltaX: scrollDeltaX, deltaY: scrollDeltaY, at: point)

            // Track last delta for momentum (using nanoseconds)
            let timeDelta = now - state.lastMoveTime
            if timeDelta > 0 && timeDelta < 100_000_000 {  // Within 100ms
                state.lastDeltaX = scrollDeltaX
                state.lastDeltaY = scrollDeltaY
            }
            state.lastMoveTime = now
        }

        state.lastPosition = point
        touchState = state
        lastMousePosition = point
    }

    private func handleTouchUp(at point: CGPoint) {
        guard let state = touchState else { return }

        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now - state.startTime

        // Simple logic: if still a tap (didn't move much) AND quick enough = click
        if state.isTap && elapsed < GestureThresholds.tapMaxTime {
            performClick(at: point)
        } else if !state.isTap {
            // Was scrolling - check if we should start momentum
            let timeSinceLastMove = now - state.lastMoveTime

            // Only start momentum if finger was recently moving (within 50ms)
            if timeSinceLastMove < 50_000_000 {
                let momentumThreshold: CGFloat = 2.0
                if abs(state.lastDeltaX) > momentumThreshold || abs(state.lastDeltaY) > momentumThreshold {
                    let momentumMultiplier: CGFloat = 6.0
                    startMomentumScroll(
                        velocityX: state.lastDeltaX * momentumMultiplier,
                        velocityY: state.lastDeltaY * momentumMultiplier,
                        at: point
                    )
                }
            }
        }

        touchState = nil
    }

    private func performClick(at point: CGPoint) {
        // Mouse down
        if let downEvent = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            downEvent.setIntegerValueField(.mouseEventClickState, value: 1)
            downEvent.post(tap: .cghidEventTap)
        }

        // Mouse up
        if let upEvent = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            upEvent.setIntegerValueField(.mouseEventClickState, value: 1)
            upEvent.post(tap: .cghidEventTap)
        }
    }

    private func injectScrollEvent(deltaX: CGFloat, deltaY: CGFloat, at position: CGPoint) {
        // Natural scrolling - content moves with finger direction (like iOS/trackpad)
        let scrollY = Int32(deltaY)
        let scrollX = Int32(deltaX)

        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: scrollY,
            wheel2: scrollX,
            wheel3: 0
        ) else {
            print("❌ Failed to create scroll event")
            return
        }

        scrollEvent.location = position
        scrollEvent.post(tap: CGEventTapLocation.cghidEventTap)
    }

    // MARK: - Momentum Scrolling

    private func startMomentumScroll(velocityX: CGFloat, velocityY: CGFloat, at position: CGPoint) {
        stopMomentumScroll()  // Cancel any existing momentum

        momentumVelocityX = velocityX
        momentumVelocityY = velocityY
        lastMomentumPosition = position

        // Schedule timer on main run loop
        momentumTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.momentumTick()
        }
    }

    private func momentumTick() {
        let decelerationRate: CGFloat = 0.92  // Slightly faster decay for snappier feel
        let minVelocity: CGFloat = 0.5

        // Stop if velocity is negligible
        if abs(momentumVelocityX) < minVelocity && abs(momentumVelocityY) < minVelocity {
            stopMomentumScroll()
            return
        }

        // Inject scroll event
        injectScrollEvent(deltaX: momentumVelocityX, deltaY: momentumVelocityY, at: lastMomentumPosition)

        // Decay velocity exponentially
        momentumVelocityX *= decelerationRate
        momentumVelocityY *= decelerationRate
    }

    private func stopMomentumScroll() {
        momentumTimer?.invalidate()
        momentumTimer = nil
        momentumVelocityX = 0
        momentumVelocityY = 0
        NSCursor.unhide()  // Show cursor when momentum ends
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
