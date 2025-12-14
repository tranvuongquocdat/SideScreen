import Cocoa
import ScreenCaptureKit
import SwiftUI

@available(macOS 14.0, *)
class AppDelegate: NSObject, NSApplicationDelegate {
    var streamingServer: StreamingServer?
    var screenCapture: ScreenCapture?
    var virtualDisplayManager: VirtualDisplayManager?
    var settings = DisplaySettings()
    var settingsWindow: SettingsWindowController?
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("✅ App launched")

        // Create menu bar item
        setupMenuBar()

        // Setup settings window
        setupSettingsWindow()

        // Check permissions
        Task {
            await checkPermissions()
        }

        // Show settings window
        showSettings()
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
            // Don't show alert on app launch - only when user tries to start server
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

            // Setup capture
            print("🔨 Setting up screen capture...")
            guard let displayID = virtualDisplayManager?.displayID else {
                print("❌ Display ID is nil")
                return
            }
            print("📺 Display ID: \(displayID)")
            screenCapture = try await ScreenCapture()
            try await screenCapture?.setupForVirtualDisplay(displayID)
            print("✅ Screen capture setup complete")

            // Setup server
            print("🔨 Setting up streaming server...")
            streamingServer = StreamingServer(port: settings.port)
            streamingServer?.setDisplaySize(width: size.width, height: size.height)
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
            screenCapture?.startStreaming(to: streamingServer)

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

    func handleTouch(x: Float, y: Float, action: Int) {
        guard let displayID = virtualDisplayManager?.displayID else { return }

        guard let bounds = CGDisplayBounds(displayID) as CGRect? else { return }

        let absoluteX = bounds.origin.x + (CGFloat(x) * bounds.width)
        let absoluteY = bounds.origin.y + (CGFloat(y) * bounds.height)

        let point = CGPoint(x: absoluteX, y: absoluteY)

        let eventType: CGEventType
        switch action {
        case 0:
            eventType = .leftMouseDown
        case 1:
            eventType = .leftMouseDragged
        case 2:
            eventType = .leftMouseUp
        default:
            return
        }

        if let event = CGEvent(mouseEventSource: nil, mouseType: eventType, mouseCursorPosition: point, mouseButton: .left) {
            if action == 0 {
                let localPoint = CGPoint(x: CGFloat(x) * bounds.width, y: CGFloat(y) * bounds.height)
                CGDisplayMoveCursorToPoint(displayID, localPoint)
            }
            event.post(tap: .cghidEventTap)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopServer()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
