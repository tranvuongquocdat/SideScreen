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
            HStack(spacing: 14) {
                // App icon
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(
                            colors: [Color.blue, Color.blue.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 44, height: 44)
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Side Screen")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Your second display for macOS")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Reset button
                Button(action: {
                    showResetConfirmation = true
                }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Reset settings")
                .alert("Reset Settings", isPresented: $showResetConfirmation) {
                    Button("Cancel", role: .cancel) { }
                    Button("Reset", role: .destructive) {
                        settings.resetToDefaults()
                        if let window = NSApp.windows.first(where: { $0.title == "Side Screen" }) {
                            window.center()
                        }
                    }
                } message: {
                    Text("This will reset all settings to default values.")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Display Configuration
                    GroupBox {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Display Configuration")
                                .font(.system(size: 13, weight: .semibold))

                            // Resolution (grouped by aspect ratio)
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

                                // Grouped resolution list
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 0) {
                                        if settings.showAllResolutions {
                                            // Show grouped by aspect ratio
                                            ForEach(DisplaySettings.resolutionGroups) { group in
                                                // Group header
                                                HStack(spacing: 6) {
                                                    Text(group.name)
                                                        .font(.system(size: 11, weight: .semibold))
                                                    Text(group.ratio)
                                                        .font(.system(size: 10))
                                                        .foregroundColor(.secondary)
                                                }
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(Color(NSColor.windowBackgroundColor))

                                                // Resolutions in group
                                                ForEach(group.resolutions, id: \.self) { res in
                                                    ResolutionRow(resolution: res, isSelected: settings.resolution == res) {
                                                        settings.resolution = res
                                                    }
                                                }
                                            }
                                        } else {
                                            // Show common resolutions only
                                            ForEach(DisplaySettings.commonResolutions, id: \.self) { res in
                                                ResolutionRow(resolution: res, isSelected: settings.resolution == res) {
                                                    settings.resolution = res
                                                }
                                            }
                                        }
                                    }
                                }
                                .frame(height: 180)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                                )

                                // Custom resolution input
                                if settings.showAllResolutions {
                                    HStack(spacing: 8) {
                                        TextField("W", value: $settings.customWidth, format: .number)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 70)
                                        Text("×")
                                            .foregroundColor(.secondary)
                                        TextField("H", value: $settings.customHeight, format: .number)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 70)
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
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Bitrate")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("\(settings.effectiveBitrate) Mbps")
                                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                        .foregroundColor(.accentColor)
                                }

                                // Bitrate preset buttons
                                HStack(spacing: 6) {
                                    BitrateButton(label: "100", value: 100, currentValue: settings.bitrate, disabled: settings.gamingBoost) {
                                        settings.bitrate = 100
                                    }
                                    BitrateButton(label: "300", value: 300, currentValue: settings.bitrate, disabled: settings.gamingBoost) {
                                        settings.bitrate = 300
                                    }
                                    BitrateButton(label: "500", value: 500, currentValue: settings.bitrate, disabled: settings.gamingBoost) {
                                        settings.bitrate = 500
                                    }
                                    BitrateButton(label: "1000", value: 1000, currentValue: settings.bitrate, disabled: settings.gamingBoost) {
                                        settings.bitrate = 1000
                                    }
                                    BitrateButton(label: "2000", value: 2000, currentValue: settings.bitrate, disabled: settings.gamingBoost) {
                                        settings.bitrate = 2000
                                    }
                                }

                                // Fine-tune slider
                                HStack(spacing: 8) {
                                    Text("20")
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                    Slider(value: Binding(
                                        get: { Double(settings.bitrate) },
                                        set: { settings.bitrate = Int($0) }
                                    ), in: 20...5000, step: 10)
                                    .disabled(settings.gamingBoost)
                                    Text("5000")
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }

                                if settings.gamingBoost {
                                    HStack(spacing: 4) {
                                        Image(systemName: "bolt.fill")
                                            .font(.system(size: 10))
                                        Text("Locked at 1000 Mbps in Gaming Boost")
                                            .font(.system(size: 10))
                                    }
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

                            // Screen Recording permission warning
                            if !settings.hasScreenRecordingPermission {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(.orange)
                                            .font(.system(size: 14))
                                        Text("Screen Recording permission required")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(.orange)
                                    }
                                    Text("Required to capture and stream the virtual display.")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Button(action: {
                                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                                    }) {
                                        HStack {
                                            Image(systemName: "gear")
                                            Text("Open System Settings")
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                                .padding(10)
                                .background(Color.orange.opacity(0.1))
                                .cornerRadius(8)
                            }

                            // Accessibility permission warning
                            if !settings.hasAccessibilityPermission {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "hand.tap.fill")
                                            .foregroundColor(.blue)
                                            .font(.system(size: 18))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Enable Touch Control")
                                                .font(.system(size: 13, weight: .semibold))
                                            Text("Control your Mac from your tablet")
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                        }
                                    }

                                    VStack(alignment: .leading, spacing: 6) {
                                        Label("Open System Settings → Privacy & Security", systemImage: "1.circle.fill")
                                            .font(.system(size: 11))
                                        Label("Select Accessibility in the left sidebar", systemImage: "2.circle.fill")
                                            .font(.system(size: 11))
                                        Label("Turn on Side Screen", systemImage: "3.circle.fill")
                                            .font(.system(size: 11))
                                    }
                                    .foregroundColor(.secondary)

                                    Button(action: {
                                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                                    }) {
                                        HStack {
                                            Image(systemName: "gear")
                                            Text("Open Settings")
                                        }
                                        .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.regular)
                                }
                                .padding(12)
                                .background(Color.blue.opacity(0.08))
                                .cornerRadius(10)
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
            HStack(spacing: 12) {
                Button(action: { settings.toggleServer() }) {
                    HStack(spacing: 6) {
                        Image(systemName: settings.isRunning ? "stop.fill" : "play.fill")
                            .font(.system(size: 12))
                        Text(settings.isRunning ? "Stop" : "Start")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .frame(width: 90)
                }
                .buttonStyle(.borderedProminent)
                .tint(settings.isRunning ? .red : .accentColor)
                .controlSize(.large)
                .disabled(!settings.hasScreenRecordingPermission)

                if settings.isRunning {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("Running on port \(settings.port)")
                            .font(.system(size: 12))
                            .foregroundColor(.primary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(8)
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 480, height: 780)
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

struct ResolutionRow: View {
    let resolution: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(resolution.replacingOccurrences(of: "x", with: " × "))
                    .font(.system(size: 12))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor : Color.clear)
            .foregroundColor(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

struct BitrateButton: View {
    let label: String
    let value: Int
    let currentValue: Int
    let disabled: Bool
    let action: () -> Void

    var isSelected: Bool { currentValue == value }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color(NSColor.controlBackgroundColor))
                .foregroundColor(isSelected ? .white : (disabled ? .secondary : .primary))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.clear : Color(NSColor.separatorColor), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
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

    // Resolution groups by aspect ratio
    struct ResolutionGroup: Identifiable {
        let id = UUID()
        let name: String
        let ratio: String
        let resolutions: [String]
    }

    static let resolutionGroups: [ResolutionGroup] = [
        ResolutionGroup(name: "16:10", ratio: "Widescreen", resolutions: [
            "1280x800", "1440x900", "1680x1050", "1920x1200", "2560x1600"
        ]),
        ResolutionGroup(name: "16:9", ratio: "HD/4K", resolutions: [
            "1280x720", "1366x768", "1600x900", "1920x1080", "2560x1440", "3840x2160"
        ]),
        ResolutionGroup(name: "4:3", ratio: "Classic", resolutions: [
            "1024x768", "1280x960", "1600x1200"
        ]),
        ResolutionGroup(name: "3:2", ratio: "Surface/Pixel", resolutions: [
            "1920x1280", "2160x1440", "2736x1824"
        ]),
        ResolutionGroup(name: "5:3", ratio: "Tablet Wide", resolutions: [
            "2000x1200", "2560x1536", "2800x1680"
        ]),
        ResolutionGroup(name: "4:3", ratio: "iPad", resolutions: [
            "2048x1536", "2224x1668", "2388x1668", "2732x2048"
        ])
    ]

    // Common resolutions (default view)
    static let commonResolutions = [
        "1920x1080", "1920x1200", "2560x1440", "2560x1600"
    ]

    // All resolutions flat list
    static var allResolutions: [String] {
        resolutionGroups.flatMap { $0.resolutions }
    }

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
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 780),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Side Screen"
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
