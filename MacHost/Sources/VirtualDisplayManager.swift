import Foundation
import CoreGraphics
import CGVirtualDisplayBridge

/// Manages virtual display creation and lifecycle using CGVirtualDisplay API
@available(macOS 14.0, *)
class VirtualDisplayManager {
    private var virtualDisplay: CGVirtualDisplay?
    private var displayDescriptor: CGVirtualDisplayDescriptor?
    private var displaySettings: CGVirtualDisplaySettings?

    var displayID: CGDirectDisplayID? {
        return virtualDisplay?.displayID
    }

    var isActive: Bool {
        return virtualDisplay != nil
    }

    /// Create a virtual display with specified configuration
    /// - Parameters:
    ///   - width: Display width in pixels
    ///   - height: Display height in pixels
    ///   - refreshRate: Refresh rate in Hz (default: 60)
    ///   - hiDPI: Enable HiDPI mode (default: false)
    ///   - name: Display name (default: "Virtual Display")
    func createDisplay(
        width: Int,
        height: Int,
        refreshRate: Int = 60,
        hiDPI: Bool = false,
        name: String = "Virtual Display"
    ) throws {
        // Clean up existing display if any
        destroyDisplay()

        // Create display descriptor
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(width)
        descriptor.maxPixelsHigh = UInt32(height)

        // Calculate physical size (assuming ~110 PPI for tablet)
        let ratio: Double = 25.4 / 110.0 // mm per pixel
        descriptor.sizeInMillimeters = CGSize(
            width: Double(width) * ratio,
            height: Double(height) * ratio
        )

        // Set vendor/product IDs
        descriptor.productID = UInt32(0xEEEE + width + height)
        descriptor.vendorID = 0xEEEE
        descriptor.serialNum = 0x0001

        self.displayDescriptor = descriptor

        // Create display settings
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0

        // Create display mode
        let mode = CGVirtualDisplayMode(
            width: UInt32(width),
            height: UInt32(height),
            refreshRate: Double(refreshRate)
        )
        settings.modes = [mode]

        self.displaySettings = settings

        // Create virtual display
        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            throw VirtualDisplayError.creationFailed("Failed to create CGVirtualDisplay")
        }

        self.virtualDisplay = display

        // Apply settings
        let result = display.apply(settings)
        if !result {
            destroyDisplay()
            throw VirtualDisplayError.settingsApplyFailed("Failed to apply settings")
        }

        print("✅ Virtual display created: \(width)x\(height) @ \(refreshRate)Hz (ID: \(display.displayID))")
    }

    /// Clone the main display configuration
    func cloneMainDisplay() throws {
        guard let mainDisplay = CGMainDisplayID() as CGDirectDisplayID? else {
            throw VirtualDisplayError.mainDisplayNotFound
        }

        let width = Int(CGDisplayPixelsWide(mainDisplay))
        let height = Int(CGDisplayPixelsHigh(mainDisplay))

        // Get refresh rate
        var refreshRate = 60
        if let mode = CGDisplayCopyDisplayMode(mainDisplay) {
            refreshRate = Int(mode.refreshRate)
        }

        try createDisplay(
            width: width,
            height: height,
            refreshRate: refreshRate,
            name: "Virtual Display (Clone)"
        )
    }

    /// Enable mirror mode with main display
    func enableMirrorMode() throws {
        guard let display = virtualDisplay else {
            throw VirtualDisplayError.displayNotCreated
        }

        let mainDisplay = CGMainDisplayID()

        var config: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&config)

        guard beginResult == CGError.success, let config = config else {
            throw VirtualDisplayError.configurationFailed("Failed to begin display configuration")
        }

        let mirrorResult = CGConfigureDisplayMirrorOfDisplay(
            config,
            display.displayID,
            mainDisplay
        )

        if mirrorResult != CGError.success {
            CGCancelDisplayConfiguration(config)
            throw VirtualDisplayError.mirrorModeFailed("Failed to configure mirror mode: \(mirrorResult)")
        }

        let completeResult = CGCompleteDisplayConfiguration(config, .permanently)

        if completeResult != CGError.success {
            throw VirtualDisplayError.mirrorModeFailed("Failed to complete mirror configuration: \(completeResult)")
        }

        print("✅ Mirror mode enabled")
    }

    /// Disable mirror mode (extend mode)
    func disableMirrorMode() throws {
        guard let display = virtualDisplay else {
            throw VirtualDisplayError.displayNotCreated
        }

        var config: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&config)

        guard beginResult == CGError.success, let config = config else {
            throw VirtualDisplayError.configurationFailed("Failed to begin display configuration")
        }

        // Setting mirror to kCGNullDirectDisplay disables mirroring
        let mirrorResult = CGConfigureDisplayMirrorOfDisplay(
            config,
            display.displayID,
            CGDirectDisplayID(kCGNullDirectDisplay)
        )

        if mirrorResult != CGError.success {
            CGCancelDisplayConfiguration(config)
            throw VirtualDisplayError.mirrorModeFailed("Failed to disable mirror mode: \(mirrorResult)")
        }

        let completeResult = CGCompleteDisplayConfiguration(config, .permanently)

        if completeResult != CGError.success {
            throw VirtualDisplayError.mirrorModeFailed("Failed to complete configuration: \(completeResult)")
        }

        print("✅ Extend mode enabled (mirror disabled)")
    }

    /// Destroy the virtual display
    func destroyDisplay() {
        if virtualDisplay != nil {
            virtualDisplay = nil
            displayDescriptor = nil
            displaySettings = nil
            print("🗑️  Virtual display destroyed")
        }
    }

    deinit {
        destroyDisplay()
    }
}

// MARK: - Error Types
enum VirtualDisplayError: Error, LocalizedError {
    case creationFailed(String)
    case settingsApplyFailed(String)
    case displayNotCreated
    case mainDisplayNotFound
    case configurationFailed(String)
    case mirrorModeFailed(String)

    var errorDescription: String? {
        switch self {
        case .creationFailed(let msg):
            return "Virtual display creation failed: \(msg)"
        case .settingsApplyFailed(let msg):
            return "Settings apply failed: \(msg)"
        case .displayNotCreated:
            return "Virtual display has not been created"
        case .mainDisplayNotFound:
            return "Main display not found"
        case .configurationFailed(let msg):
            return "Display configuration failed: \(msg)"
        case .mirrorModeFailed(let msg):
            return "Mirror mode operation failed: \(msg)"
        }
    }
}
