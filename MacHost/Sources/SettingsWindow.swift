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

                            // Resolution (macOS-style scrollable list)
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Resolution")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Toggle("Show all", isOn: $settings.showAllResolutions)
                                        .toggleStyle(.switch)
                                        .controlSize(.mini)
                                }

                                // Scrollable resolution list like macOS Display Settings
                                ScrollView {
                                    VStack(spacing: 0) {
                                        let resolutions = settings.showAllResolutions
                                            ? DisplaySettings.allResolutions
                                            : DisplaySettings.commonResolutions

                                        ForEach(resolutions, id: \.self) { res in
                                            Button(action: { settings.resolution = res }) {
                                                HStack {
                                                    Text(res.replacingOccurrences(of: "x", with: " × "))
                                                        .font(.system(size: 12))
                                                    Spacer()
                                                }
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                                .background(settings.resolution == res ? Color.accentColor : Color.clear)
                                                .foregroundColor(settings.resolution == res ? .white : .primary)
                                            }
                                            .buttonStyle(.plain)

                                            if res != resolutions.last {
                                                Divider().padding(.leading, 12)
                                            }
                                        }
                                    }
                                }
                                .frame(height: 150)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                                )

                                // Custom resolution input
                                if settings.showAllResolutions {
                                    HStack(spacing: 8) {
                                        TextField("W", value: $settings.customWidth, format: .number)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 60)
                                        Text("×")
                                            .foregroundColor(.secondary)
                                        TextField("H", value: $settings.customHeight, format: .number)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 60)
                                        Button("Apply") {
                                            settings.applyCustomResolution()
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                }
                            }

                            // Rotation (visual 4-corner selector)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Rotation")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)

                                HStack(spacing: 12) {
                                    // Visual display preview with rotation buttons
                                    ZStack {
                                        // Display frame
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(Color.secondary, lineWidth: 1)
                                            .frame(width: 80, height: 50)
                                            .rotationEffect(.degrees(Double(settings.rotation)))

                                        // Rotation indicator
                                        Text(settings.rotation == 90 || settings.rotation == 270 ? "Portrait" : "Landscape")
                                            .font(.system(size: 8))
                                            .foregroundColor(.secondary)
                                    }
                                    .frame(width: 100, height: 80)

                                    // Rotation buttons grid
                                    VStack(spacing: 6) {
                                        HStack(spacing: 6) {
                                            RotationButton(degrees: 270, label: "↺ 270°", isSelected: settings.rotation == 270) {
                                                settings.rotation = 270
                                            }
                                            RotationButton(degrees: 0, label: "0°", isSelected: settings.rotation == 0) {
                                                settings.rotation = 0
                                            }
                                            RotationButton(degrees: 90, label: "90° ↻", isSelected: settings.rotation == 90) {
                                                settings.rotation = 90
                                            }
                                        }
                                        HStack(spacing: 6) {
                                            Spacer()
                                            RotationButton(degrees: 180, label: "180°", isSelected: settings.rotation == 180) {
                                                settings.rotation = 180
                                            }
                                            Spacer()
                                        }
                                    }
                                }

                                if settings.rotation == 90 || settings.rotation == 270 {
                                    Text("Display will be in portrait mode")
                                        .font(.system(size: 10))
                                        .foregroundColor(.blue)
                                }
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
                            StatusRow(title: "Accessibility (Touch)", status: settings.hasAccessibilityPermission ? "Granted" : "Not Granted", color: settings.hasAccessibilityPermission ? .green : .red)

                            if !settings.hasScreenRecordingPermission || !settings.hasAccessibilityPermission {
                                VStack(alignment: .leading, spacing: 4) {
                                    if !settings.hasScreenRecordingPermission {
                                        Button("Grant Screen Recording Permission") {
                                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                                        }
                                        .buttonStyle(.link)
                                        .font(.system(size: 11))
                                    }
                                    if !settings.hasAccessibilityPermission {
                                        Button("Grant Accessibility Permission (for touch control)") {
                                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                                        }
                                        .buttonStyle(.link)
                                        .font(.system(size: 11))
                                    }
                                }
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
        .frame(width: 500, height: 820)
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
struct RotationButton: View {
    let degrees: Int
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                // Mini display icon
                RoundedRectangle(cornerRadius: 2)
                    .stroke(isSelected ? Color.accentColor : Color.secondary, lineWidth: 1)
                    .frame(width: degrees == 90 || degrees == 270 ? 16 : 24, height: degrees == 90 || degrees == 270 ? 24 : 16)

                Text(label)
                    .font(.system(size: 9))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .frame(width: 60, height: 45)
            .contentShape(Rectangle()) // Makes entire area clickable
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.borderless) // Better than .plain for macOS
    }
}

@available(macOS 14.0, *)
class DisplaySettings: ObservableObject {
    private let defaults = UserDefaults.standard
    private let keyPrefix = "VirtualDisplay_"

    @Published var resolution: String {
        didSet { save("resolution", resolution) }
    }
    @Published var refreshRate: Int {
        didSet { save("refreshRate", refreshRate) }
    }
    @Published var hiDPI: Bool {
        didSet { save("hiDPI", hiDPI) }
    }
    @Published var bitrate: Int {
        didSet { save("bitrate", bitrate) }
    }
    @Published var quality: String {
        didSet { save("quality", quality) }
    }
    @Published var gamingBoost: Bool {
        didSet { save("gamingBoost", gamingBoost) }
    }
    @Published var port: UInt16 {
        didSet { save("port", Int(port)) }
    }
    @Published var rotation: Int {
        didSet { save("rotation", rotation) }
    }
    @Published var showAllResolutions: Bool {
        didSet { save("showAllResolutions", showAllResolutions) }
    }
    @Published var customWidth: Int {
        didSet { save("customWidth", customWidth) }
    }
    @Published var customHeight: Int {
        didSet { save("customHeight", customHeight) }
    }

    // Runtime state (not persisted)
    @Published var displayCreated = false
    @Published var clientConnected = false
    @Published var hasScreenRecordingPermission = false
    @Published var hasAccessibilityPermission = false
    @Published var isRunning = false
    @Published var currentFPS: Double = 0
    @Published var currentBitrate: Double = 0

    var onToggleServer: (() -> Void)?

    init() {
        // Load saved settings or use defaults
        self.resolution = defaults.string(forKey: keyPrefix + "resolution") ?? "1920x1200"
        self.refreshRate = defaults.object(forKey: keyPrefix + "refreshRate") as? Int ?? 60
        self.hiDPI = defaults.bool(forKey: keyPrefix + "hiDPI")
        self.bitrate = defaults.object(forKey: keyPrefix + "bitrate") as? Int ?? 500
        self.quality = defaults.string(forKey: keyPrefix + "quality") ?? "medium"
        self.gamingBoost = defaults.bool(forKey: keyPrefix + "gamingBoost")
        self.port = UInt16(defaults.object(forKey: keyPrefix + "port") as? Int ?? 8888)
        self.rotation = defaults.object(forKey: keyPrefix + "rotation") as? Int ?? 0
        self.showAllResolutions = defaults.bool(forKey: keyPrefix + "showAllResolutions")
        self.customWidth = defaults.object(forKey: keyPrefix + "customWidth") as? Int ?? 1920
        self.customHeight = defaults.object(forKey: keyPrefix + "customHeight") as? Int ?? 1200

        print("📂 Loaded settings: \(resolution) @ \(refreshRate)Hz, bitrate=\(bitrate), quality=\(quality)")
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: keyPrefix + key)
    }

    // Common resolutions (default view)
    static let commonResolutions = [
        "1600x1000", "1920x1080", "1920x1200",
        "2560x1440", "2560x1600"
    ]

    // Extended resolution list (like macOS Display Settings)
    static let allResolutions = [
        // 16:10 ratios
        "1280x800", "1440x900", "1680x1050", "1920x1200", "2560x1600",
        // 16:9 ratios
        "1280x720", "1366x768", "1600x900", "1920x1080", "2560x1440", "3840x2160",
        // 4:3 ratios
        "1024x768", "1280x960", "1600x1200",
        // 3:2 ratios (Surface, Pixel tablets)
        "1920x1280", "2160x1440", "2736x1824",
        // Common tablet ratios
        "2000x1200", "2224x1668", "2388x1668", "2732x2048", "2800x1752"
    ]

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
        // Clear all saved settings
        let keys = ["resolution", "refreshRate", "hiDPI", "bitrate", "quality",
                    "gamingBoost", "port", "rotation", "showAllResolutions",
                    "customWidth", "customHeight"]
        for key in keys {
            defaults.removeObject(forKey: keyPrefix + key)
        }

        // Reset to defaults
        resolution = "1920x1200"
        refreshRate = 60
        hiDPI = false
        bitrate = 500
        quality = "medium"
        gamingBoost = false
        port = 8888
        rotation = 0
        showAllResolutions = false
        customWidth = 1920
        customHeight = 1200

        print("🔄 Settings reset to defaults")
    }

    var resolutionSize: (width: Int, height: Int) {
        let parts = resolution.split(separator: "x")
        let baseWidth = Int(parts[0]) ?? 1920
        let baseHeight = Int(parts[1]) ?? 1200
        // Swap dimensions for portrait orientations (90° or 270°)
        if rotation == 90 || rotation == 270 {
            return (baseHeight, baseWidth)
        }
        return (baseWidth, baseHeight)
    }

    func applyCustomResolution() {
        if customWidth >= 640 && customWidth <= 7680 && customHeight >= 480 && customHeight <= 4320 {
            resolution = "\(customWidth)x\(customHeight)"
        }
    }
}

@available(macOS 14.0, *)
class SettingsWindowController: NSWindowController, NSWindowDelegate {
    convenience init(settings: DisplaySettings) {
        let window = ConstrainedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 820),
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
