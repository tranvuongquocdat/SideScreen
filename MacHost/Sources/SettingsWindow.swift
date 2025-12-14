import Cocoa
import SwiftUI

@available(macOS 14.0, *)
struct SettingsView: View {
    @ObservedObject var settings: DisplaySettings
    @State private var showPermissionAlert = false
    @State private var showResetConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "display.2")
                    .font(.system(size: 32))
                    .foregroundColor(.blue)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Virtual Display")
                        .font(.system(size: 24, weight: .semibold))
                    Text("Configure your second screen")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Reset button
                Button(action: {
                    showResetConfirmation = true
                }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .help("Reset window position and settings")
                .alert("Reset Settings", isPresented: $showResetConfirmation) {
                    Button("Cancel", role: .cancel) { }
                    Button("Reset", role: .destructive) {
                        settings.resetToDefaults()
                        if let window = NSApp.windows.first(where: { $0.title == "Virtual Display Settings" }) {
                            window.center()
                        }
                    }
                } message: {
                    Text("This will reset all settings to default values and center the window.")
                }
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Display Configuration
                    GroupBox {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Display Configuration")
                                .font(.system(size: 13, weight: .semibold))

                            // Resolution
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Resolution")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)

                                Picker("", selection: $settings.resolution) {
                                    Text("1600 × 1000").tag("1600x1000")
                                    Text("1920 × 1080").tag("1920x1080")
                                    Text("1920 × 1200").tag("1920x1200")
                                    Text("2560 × 1440").tag("2560x1440")
                                    Text("2560 × 1600").tag("2560x1600")
                                }
                                .pickerStyle(.segmented)
                            }

                            // Refresh Rate
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Refresh Rate")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("\(settings.refreshRate) Hz")
                                        .font(.system(size: 11, weight: .medium))
                                }

                                Picker("", selection: $settings.refreshRate) {
                                    Text("30 Hz").tag(30)
                                    Text("60 Hz (Balanced)").tag(60)
                                    Text("90 Hz (Smooth)").tag(90)
                                    Text("120 Hz (Ultra)").tag(120)
                                }
                                .pickerStyle(.segmented)

                                if settings.refreshRate >= 90 {
                                    Text("High refresh rate for competitive gaming")
                                        .font(.system(size: 10))
                                        .foregroundColor(.green)
                                }
                            }

                            // HiDPI
                            Toggle("Enable HiDPI (Retina)", isOn: $settings.hiDPI)
                                .font(.system(size: 12))
                        }
                        .padding(12)
                    }

                    // Network Settings
                    GroupBox {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Network Settings")
                                .font(.system(size: 13, weight: .semibold))

                            // Port
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Server Port")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    TextField("Port", value: $settings.port, format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                        .disabled(settings.isRunning)
                                }

                                if settings.isRunning {
                                    Text("Stop server to change port")
                                        .font(.system(size: 10))
                                        .foregroundColor(.orange)
                                } else if settings.port != 8888 {
                                    Text("Enter this port in the Android client app")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(12)
                    }

                    // Gaming Boost Mode
                    GroupBox {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Image(systemName: settings.gamingBoost ? "bolt.fill" : "bolt.slash.fill")
                                    .foregroundColor(settings.gamingBoost ? .orange : .secondary)
                                    .font(.system(size: 16))

                                Text("Gaming Boost")
                                    .font(.system(size: 13, weight: .semibold))

                                Spacer()

                                Toggle("", isOn: $settings.gamingBoost)
                                    .labelsHidden()
                            }

                            if settings.gamingBoost {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                            .font(.system(size: 10))
                                        Text("High bitrate (1000 Mbps)")
                                            .font(.system(size: 11))
                                    }
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                            .font(.system(size: 10))
                                        Text("120 Hz refresh rate")
                                            .font(.system(size: 11))
                                    }
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                            .font(.system(size: 10))
                                        Text("Ultra-low latency encoding")
                                            .font(.system(size: 11))
                                    }
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                            .font(.system(size: 10))
                                        Text("Optimized for FPS games")
                                            .font(.system(size: 11))
                                    }
                                }
                                .padding(.leading, 20)
                                .foregroundColor(.secondary)
                            } else {
                                Text("Enable for competitive gaming with minimal input lag")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(12)
                    }

                    // Streaming Settings
                    GroupBox {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Streaming Settings")
                                .font(.system(size: 13, weight: .semibold))

                            // Bitrate
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Bitrate")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("\(settings.effectiveBitrate) Mbps")
                                        .font(.system(size: 11, weight: .medium))
                                }

                                Slider(value: Binding(
                                    get: { Double(settings.bitrate) },
                                    set: { settings.bitrate = Int($0) }
                                ), in: 20...5000, step: 50)
                                .disabled(settings.gamingBoost)

                                Text("USB 3.1 Gen 2: up to 5 Gbps (5000 Mbps) bandwidth")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)

                                if settings.gamingBoost {
                                    Text("Bitrate locked at 1000 Mbps in Gaming Boost mode")
                                        .font(.system(size: 10))
                                        .foregroundColor(.orange)
                                }
                            }

                            // Quality
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Quality Preset")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)

                                Picker("", selection: $settings.quality) {
                                    Text("Low (Fast)").tag("low")
                                    Text("Medium").tag("medium")
                                    Text("High (Slow)").tag("high")
                                }
                                .pickerStyle(.segmented)
                                .disabled(settings.gamingBoost)

                                if settings.gamingBoost {
                                    Text("Quality locked to Low in Gaming Boost mode")
                                        .font(.system(size: 10))
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                        .padding(12)
                    }

                    // Status
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Status")
                                .font(.system(size: 13, weight: .semibold))

                            StatusRow(title: "Virtual Display", status: settings.displayCreated ? "Active" : "Inactive", color: settings.displayCreated ? .green : .secondary)
                            StatusRow(title: "Client Connected", status: settings.clientConnected ? "Yes" : "No", color: settings.clientConnected ? .green : .secondary)
                            StatusRow(title: "Screen Recording", status: settings.hasScreenRecordingPermission ? "Granted" : "Not Granted", color: settings.hasScreenRecordingPermission ? .green : .red)

                            if !settings.hasScreenRecordingPermission {
                                Button("Open System Settings") {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                                }
                                .buttonStyle(.link)
                                .font(.system(size: 11))
                            }
                        }
                        .padding(12)
                    }

                    // Performance
                    if settings.clientConnected {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Performance")
                                    .font(.system(size: 13, weight: .semibold))

                                HStack {
                                    VStack(alignment: .leading) {
                                        Text("FPS")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                        Text(String(format: "%.1f", settings.currentFPS))
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.green)
                                    }

                                    Spacer()

                                    VStack(alignment: .leading) {
                                        Text("Bitrate")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                        Text(String(format: "%.1f Mbps", settings.currentBitrate))
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.blue)
                                    }
                                }
                            }
                            .padding(12)
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer
            HStack {
                Button(settings.isRunning ? "Stop Server" : "Start Server") {
                    settings.toggleServer()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!settings.hasScreenRecordingPermission)

                Spacer()

                if settings.isRunning {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("Running on port \(settings.port)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 500, height: 700)
    }
}

struct StatusRow: View {
    let title: String
    let status: String
    let color: Color

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
            Spacer()
            Text(status)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(color)
        }
    }
}

@available(macOS 14.0, *)
class DisplaySettings: ObservableObject {
    @Published var resolution = "1920x1200"
    @Published var refreshRate = 60
    @Published var hiDPI = false
    @Published var bitrate = 500
    @Published var quality = "medium"
    @Published var gamingBoost = false
    @Published var displayCreated = false
    @Published var clientConnected = false
    @Published var hasScreenRecordingPermission = false
    @Published var isRunning = false
    @Published var currentFPS: Double = 0
    @Published var currentBitrate: Double = 0
    @Published var port: UInt16 = 8888

    var onToggleServer: (() -> Void)?

    // Computed property for effective bitrate
    var effectiveBitrate: Int {
        return gamingBoost ? 1000 : bitrate
    }

    // Computed property for effective quality
    var effectiveQuality: String {
        return gamingBoost ? "low" : quality
    }

    // Computed property for effective refresh rate
    var effectiveRefreshRate: Int {
        return gamingBoost ? 120 : refreshRate
    }

    func toggleServer() {
        onToggleServer?()
    }

    func resetToDefaults() {
        resolution = "1920x1200"
        refreshRate = 60
        hiDPI = false
        bitrate = 500
        quality = "medium"
        gamingBoost = false
        port = 8888
    }

    var resolutionSize: (width: Int, height: Int) {
        let parts = resolution.split(separator: "x")
        return (Int(parts[0]) ?? 1920, Int(parts[1]) ?? 1200)
    }
}

@available(macOS 14.0, *)
class SettingsWindowController: NSWindowController, NSWindowDelegate {
    convenience init(settings: DisplaySettings) {
        let window = ConstrainedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 700),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Virtual Display Settings"
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView(settings: settings))
        window.isReleasedWhenClosed = false

        self.init(window: window)
        window.delegate = self
    }

    func windowDidMove(_ notification: Notification) {
        // Ensure window stays visible on screen
        guard let window = notification.object as? NSWindow,
              let screen = window.screen ?? NSScreen.main else { return }

        var frame = window.frame
        let visibleFrame = screen.visibleFrame
        let minVisibleWidth: CGFloat = 100
        let minVisibleHeight: CGFloat = 50

        // Constrain horizontally
        if frame.maxX < visibleFrame.minX + minVisibleWidth {
            frame.origin.x = visibleFrame.minX - frame.width + minVisibleWidth
        } else if frame.minX > visibleFrame.maxX - minVisibleWidth {
            frame.origin.x = visibleFrame.maxX - minVisibleWidth
        }

        // Constrain vertically
        if frame.maxY < visibleFrame.minY + minVisibleHeight {
            frame.origin.y = visibleFrame.minY - frame.height + minVisibleHeight
        } else if frame.minY > visibleFrame.maxY - minVisibleHeight {
            frame.origin.y = visibleFrame.maxY - minVisibleHeight
        }

        if window.frame != frame {
            window.setFrame(frame, display: true)
        }
    }
}

// Custom window class to constrain dragging
@available(macOS 14.0, *)
class ConstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let screen = screen ?? self.screen ?? NSScreen.main else {
            return frameRect
        }

        var constrainedRect = frameRect
        let visibleFrame = screen.visibleFrame
        let minVisibleWidth: CGFloat = 100
        let minVisibleHeight: CGFloat = 50

        // Keep at least minVisibleWidth pixels visible horizontally
        if constrainedRect.maxX < visibleFrame.minX + minVisibleWidth {
            constrainedRect.origin.x = visibleFrame.minX - constrainedRect.width + minVisibleWidth
        } else if constrainedRect.minX > visibleFrame.maxX - minVisibleWidth {
            constrainedRect.origin.x = visibleFrame.maxX - minVisibleWidth
        }

        // Keep at least minVisibleHeight pixels visible vertically
        if constrainedRect.maxY < visibleFrame.minY + minVisibleHeight {
            constrainedRect.origin.y = visibleFrame.minY - constrainedRect.height + minVisibleHeight
        } else if constrainedRect.minY > visibleFrame.maxY - minVisibleHeight {
            constrainedRect.origin.y = visibleFrame.maxY - minVisibleHeight
        }

        return constrainedRect
    }
}
