import Cocoa
import ScreenCaptureKit
import SwiftUI
import Combine
import ApplicationServices

// MARK: - Gesture Detection Types

enum GestureType {
    case tap
    case drag
    case scroll
}

struct TouchState {
    var startPosition: CGPoint
    var lastPosition: CGPoint
    var startTime: Date
    var gestureType: GestureType? = nil
    var accumulatedScrollX: CGFloat = 0
    var accumulatedScrollY: CGFloat = 0

    init(position: CGPoint) {
        self.startPosition = position
        self.lastPosition = position
        self.startTime = Date()
    }
}

// MARK: - Gesture Thresholds
struct GestureThresholds {
    static let tapMaxDistance: CGFloat = 15          // Max pixels for tap
    static let tapMaxTime: TimeInterval = 0.3        // Max seconds for tap
    static let scrollMinDistance: CGFloat = 20       // Min pixels to trigger scroll
    static let scrollMinVelocity: CGFloat = 50       // Min pixels/second for scroll
    static let scrollSensitivity: CGFloat = 1.0      // Scroll multiplier (reduced from 2.5)
    static let scrollThrottleInterval: TimeInterval = 0.016  // ~60fps throttle
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

        // Start permission check timer (auto-refresh every 2 seconds)
        startPermissionCheckTimer()

        // Show settings window
        showSettings()
    }

    func startPermissionCheckTimer() {
        // Only auto-check Accessibility permission (Screen Recording is stable)
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task {
                await self?.checkAccessibilityPermission()
            }
        }
    }

    func stopPermissionCheckTimer() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
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
            if self?.settings.isRunning == true {
                self?.stopServer()
            } else {
                Task {
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
        // Check Screen Recording permission
        do {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            await MainActor.run {
                settings.hasScreenRecordingPermission = true
            }
            print("✅ Screen recording permission granted")
        } catch {
            await MainActor.run {
                settings.hasScreenRecordingPermission = false
            }
            print("⚠️  Screen recording permission not granted yet")
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

        do {
            // Create virtual display
            print("🔨 Creating virtual display...")
            virtualDisplayManager = VirtualDisplayManager()
            let size = settings.resolutionSize
            try virtualDisplayManager?.createDisplay(
                width: size.width,
                height: size.height,
                refreshRate: settings.refreshRate,
                hiDPI: settings.hiDPI,
                name: "TabVirtualDisplay"
            )
            print("✅ Virtual display created")

            // Disable mirror mode (optional - may fail if display is already in extend mode)
            print("🔨 Disabling mirror mode...")
            do {
                try virtualDisplayManager?.disableMirrorMode()
                print("✅ Mirror mode disabled")
            } catch {
                print("⚠️  Mirror mode already disabled or not applicable: \(error)")
                // This is not critical - continue anyway
            }

            await MainActor.run {
                settings.displayCreated = true
            }

            // Wait for display to initialize
            print("⏳ Waiting for display to initialize...")
            try await Task.sleep(nanoseconds: 500_000_000)

            // Restore saved display position (if any)
            virtualDisplayManager?.restoreDisplayPosition()

            // Setup capture
            print("🔨 Setting up screen capture...")
            guard let displayID = virtualDisplayManager?.displayID else {
                print("❌ Display ID is nil")
                return
            }
            print("📺 Display ID: \(displayID)")
            screenCapture = try await ScreenCapture()
            try await screenCapture?.setupForVirtualDisplay(displayID, refreshRate: settings.effectiveRefreshRate)
            print("✅ Screen capture setup complete")

            // Setup server
            print("🔨 Setting up streaming server...")
            streamingServer = StreamingServer(port: settings.port)
            streamingServer?.setDisplaySize(width: size.width, height: size.height, rotation: settings.rotation)
            streamingServer?.onClientConnected = { [weak self] in
                Task { @MainActor in
                    self?.settings.clientConnected = true
                }
            }

            streamingServer?.onTouchEvent = { [weak self] x, y, action in
                self?.handleTouch(x: x, y: y, action: action)
            }

            streamingServer?.onStats = { [weak self] fps, mbps in
                Task { @MainActor in
                    self?.settings.currentFPS = fps
                    self?.settings.currentBitrate = mbps
                }
            }

            print("🔨 Starting server on port \(settings.port)...")
            streamingServer?.start()
            print("🔨 Starting screen capture streaming...")
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
            print("💡 Ready to accept connections!")
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
    private var lastScrollTime: Date = .distantPast

    // Momentum scrolling
    private var momentumTimer: Timer?
    private var momentumVelocityX: CGFloat = 0
    private var momentumVelocityY: CGFloat = 0
    private var lastMomentumPosition: CGPoint = .zero
    private var lastScrollVelocityX: CGFloat = 0
    private var lastScrollVelocityY: CGFloat = 0

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
        case 0: // Touch down - start tracking
            handleTouchDown(at: point)

        case 1: // Touch move - detect gesture type and act accordingly
            handleTouchMove(to: point)

        case 2: // Touch up - finalize gesture
            handleTouchUp(at: point)

        default:
            print("⚠️ Unknown action: \(action)")
        }
    }

    // MARK: - Gesture Handling

    private func handleTouchDown(at point: CGPoint) {
        // Initialize touch state
        touchState = TouchState(position: point)
        lastMousePosition = point

        // Move cursor to position
        if let moveEvent = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
        }

        print("👇 Touch DOWN at \(point)")
    }

    private func handleTouchMove(to point: CGPoint) {
        guard var state = touchState else { return }

        let deltaX = point.x - state.lastPosition.x
        let deltaY = point.y - state.lastPosition.y
        let totalDistance = hypot(point.x - state.startPosition.x, point.y - state.startPosition.y)
        let elapsed = Date().timeIntervalSince(state.startTime)
        let velocity = elapsed > 0 ? totalDistance / CGFloat(elapsed) : 0

        // Determine gesture type if not yet determined
        if state.gestureType == nil && totalDistance > GestureThresholds.scrollMinDistance {
            // Check velocity to determine if scroll or drag
            if velocity > GestureThresholds.scrollMinVelocity {
                state.gestureType = .scroll
                stopMomentumScroll()  // Cancel any existing momentum
                NSCursor.hide()  // Hide cursor during scroll
                print("📜 Gesture detected: SCROLL (velocity: \(Int(velocity)) px/s)")
            } else {
                state.gestureType = .drag
                print("✋ Gesture detected: DRAG")
                // Start drag - send mouseDown
                if let downEvent = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: state.startPosition, mouseButton: .left) {
                    downEvent.setIntegerValueField(.mouseEventClickState, value: 1)
                    downEvent.post(tap: .cghidEventTap)
                }
            }
        }

        // Act based on gesture type
        switch state.gestureType {
        case .scroll:
            // Accumulate scroll delta
            state.accumulatedScrollX += deltaX * GestureThresholds.scrollSensitivity
            state.accumulatedScrollY += deltaY * GestureThresholds.scrollSensitivity

            // Track velocity for momentum (use per-frame delta)
            lastScrollVelocityX = deltaX * GestureThresholds.scrollSensitivity
            lastScrollVelocityY = deltaY * GestureThresholds.scrollSensitivity

            // Throttle scroll events
            let now = Date()
            if now.timeIntervalSince(lastScrollTime) >= GestureThresholds.scrollThrottleInterval {
                injectScrollEvent(deltaX: state.accumulatedScrollX, deltaY: state.accumulatedScrollY, at: point)
                state.accumulatedScrollX = 0
                state.accumulatedScrollY = 0
                lastScrollTime = now
            }

        case .drag:
            // Send drag event
            if let dragEvent = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) {
                dragEvent.post(tap: .cghidEventTap)
            }

        case .tap, .none:
            // Still undetermined or tap - just track position
            break
        }

        state.lastPosition = point
        touchState = state
        lastMousePosition = point
    }

    private func handleTouchUp(at point: CGPoint) {
        guard let state = touchState else { return }

        let totalDistance = hypot(point.x - state.startPosition.x, point.y - state.startPosition.y)
        let elapsed = Date().timeIntervalSince(state.startTime)

        // Finalize gesture type
        let finalGesture = state.gestureType ?? (
            totalDistance < GestureThresholds.tapMaxDistance && elapsed < GestureThresholds.tapMaxTime
            ? .tap : .drag
        )

        switch finalGesture {
        case .tap:
            // Perform click
            print("👆 TAP at \(point)")
            performClick(at: point)

        case .drag:
            // End drag - release mouse
            print("✋ DRAG ended at \(point)")
            if let upEvent = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
                upEvent.setIntegerValueField(.mouseEventClickState, value: 1)
                upEvent.post(tap: .cghidEventTap)
            }

        case .scroll:
            // Scroll ended - send any remaining accumulated scroll
            if abs(state.accumulatedScrollX) > 0.5 || abs(state.accumulatedScrollY) > 0.5 {
                injectScrollEvent(deltaX: state.accumulatedScrollX, deltaY: state.accumulatedScrollY, at: point)
            }

            // Start momentum scrolling if velocity is significant
            let momentumThreshold: CGFloat = 2.0
            if abs(lastScrollVelocityX) > momentumThreshold || abs(lastScrollVelocityY) > momentumThreshold {
                // Reduced multiplier for smoother momentum
                let momentumMultiplier: CGFloat = 4.0
                startMomentumScroll(
                    velocityX: lastScrollVelocityX * momentumMultiplier,
                    velocityY: lastScrollVelocityY * momentumMultiplier,
                    at: point
                )
                print("📜 SCROLL ended - starting momentum (vX: \(Int(lastScrollVelocityX)), vY: \(Int(lastScrollVelocityY)))")
            } else {
                NSCursor.unhide()  // No momentum, show cursor immediately
                print("📜 SCROLL ended")
            }

            // Reset velocity tracking
            lastScrollVelocityX = 0
            lastScrollVelocityY = 0
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
        stopServer()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
