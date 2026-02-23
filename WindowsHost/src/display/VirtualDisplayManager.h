#pragma once

#include <cstdint>
#include <string>
#include <vector>
#include <mutex>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <setupapi.h>

#include "../Config.h"

// Device interface GUID for the IddCx virtual display driver.
// Compatible with virtual-display-rs driver.
// {5765B3FD-8B01-44B0-BDBB-D9C55B3E608E}
//
// Declared here as extern; defined in VirtualDisplayManager.cpp.
EXTERN_C const GUID GUID_VIRTUAL_DISPLAY_DRIVER;

// IOCTL codes for communicating with the IddCx driver
#define IOCTL_ADD_MONITOR     CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_REMOVE_MONITOR  CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_UPDATE_MONITOR  CTL_CODE(FILE_DEVICE_UNKNOWN, 0x802, METHOD_BUFFERED, FILE_ANY_ACCESS)

/// Request structure sent to the driver when adding a monitor.
/// Must match the driver's expected layout.
#pragma pack(push, 1)
struct AddMonitorRequest {
    uint32_t width;
    uint32_t height;
    uint32_t refreshRate;
};

struct RemoveMonitorRequest {
    uint32_t monitorIndex;  // 0-based index returned by the driver
};

struct UpdateMonitorRequest {
    uint32_t monitorIndex;
    uint32_t width;
    uint32_t height;
    uint32_t refreshRate;
};
#pragma pack(pop)

/// Registry key path for persisting display position.
constexpr const wchar_t* REGISTRY_KEY_PATH = L"Software\\SideScreen";

/// Creates and manages a virtual display on Windows via an IddCx driver.
///
/// This is the user-mode counterpart to the kernel-mode IddCx Indirect Display
/// Driver. The driver must be installed separately (bundled with the installer).
/// This class communicates with the driver via DeviceIoControl to add/remove
/// virtual monitors.
///
/// Windows equivalent of the macOS VirtualDisplayManager which uses CGVirtualDisplay.
class VirtualDisplayManager {
public:
    VirtualDisplayManager();
    ~VirtualDisplayManager();

    // Non-copyable, non-movable
    VirtualDisplayManager(const VirtualDisplayManager&) = delete;
    VirtualDisplayManager& operator=(const VirtualDisplayManager&) = delete;

    /// Create a virtual display with the given resolution and refresh rate.
    /// @param width   Display width in pixels.
    /// @param height  Display height in pixels.
    /// @param refreshRate  Refresh rate in Hz.
    /// @return true on success.
    bool createDisplay(int width, int height, int refreshRate);

    /// Destroy the virtual display.
    void destroyDisplay();

    /// @return true if a virtual display is currently active.
    bool isDisplayCreated() const;

    /// Get the DXGI output index suitable for ScreenCapture::initialize().
    int displayIndex() const;

    /// Get the HMONITOR handle for the virtual display.
    HMONITOR monitorHandle() const;

    /// Current display width in pixels.
    int width() const { return width_; }

    /// Current display height in pixels.
    int height() const { return height_; }

    /// Current refresh rate in Hz.
    int refreshRate() const { return refreshRate_; }

    /// Save the current display position to the Windows Registry.
    void savePosition();

    /// Restore the saved display position from the Windows Registry.
    void restorePosition();

    /// Check if the IddCx driver is installed and accessible.
    bool isDriverInstalled() const;

private:
    /// Open a handle to the virtual display driver device.
    bool openDriverDevice();

    /// Close the driver device handle.
    void closeDriverDevice();

    /// Send IOCTL_ADD_MONITOR to the driver.
    bool sendAddMonitor(int width, int height, int refreshRate);

    /// Send IOCTL_REMOVE_MONITOR to the driver.
    bool sendRemoveMonitor();

    /// Snapshot current monitors before adding a new one.
    std::vector<HMONITOR> enumerateMonitors() const;

    /// After adding a monitor, find the new HMONITOR by diffing monitor lists.
    HMONITOR findNewMonitor(const std::vector<HMONITOR>& previousMonitors) const;

    /// Determine the DXGI output index for a given HMONITOR.
    int findDisplayIndex(HMONITOR monitor) const;

    /// Set the virtual display position using ChangeDisplaySettingsEx.
    bool setDisplayPosition(int x, int y);

    /// Read a DWORD value from the SideScreen registry key.
    bool readRegistryDword(const wchar_t* valueName, DWORD& outValue) const;

    /// Write a DWORD value to the SideScreen registry key.
    bool writeRegistryDword(const wchar_t* valueName, DWORD value) const;

    /// Log helper.
    static void log(const char* fmt, ...);

    // Driver device handle
    HANDLE deviceHandle_ = INVALID_HANDLE_VALUE;

    // Display state
    bool displayCreated_ = false;
    int displayIndex_ = -1;
    HMONITOR monitor_ = nullptr;
    uint32_t driverMonitorIndex_ = 0;  // Index returned/used by driver

    // Current configuration
    int width_ = 0;
    int height_ = 0;
    int refreshRate_ = 0;

    mutable std::mutex mutex_;
};
