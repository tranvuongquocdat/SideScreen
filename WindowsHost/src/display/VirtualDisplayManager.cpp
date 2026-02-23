#include "VirtualDisplayManager.h"

#include <cstdarg>
#include <cstdio>
#include <algorithm>
#include <thread>
#include <chrono>

#include <devguid.h>
#include <dxgi.h>
#include <wrl/client.h>

// Provide the storage for the GUID declared as extern in the header.
// {5765B3FD-8B01-44B0-BDBB-D9C55B3E608E}
extern "C" const GUID GUID_VIRTUAL_DISPLAY_DRIVER = {
    0x5765B3FD, 0x8B01, 0x44B0,
    { 0xBD, 0xBB, 0xD9, 0xC5, 0x5B, 0x3E, 0x60, 0x8E }
};

using Microsoft::WRL::ComPtr;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Callback for EnumDisplayMonitors to collect all monitors.
static BOOL CALLBACK collectMonitorsProc(HMONITOR hMonitor, HDC, LPRECT, LPARAM lParam) {
    auto* monitors = reinterpret_cast<std::vector<HMONITOR>*>(lParam);
    monitors->push_back(hMonitor);
    return TRUE;
}

// ---------------------------------------------------------------------------
// Construction / Destruction
// ---------------------------------------------------------------------------

VirtualDisplayManager::VirtualDisplayManager() = default;

VirtualDisplayManager::~VirtualDisplayManager() {
    destroyDisplay();
    closeDriverDevice();
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

bool VirtualDisplayManager::createDisplay(int width, int height, int refreshRate) {
    std::lock_guard<std::mutex> lock(mutex_);

    if (displayCreated_) {
        log("VirtualDisplayManager: display already created, destroying first");
        // Unlock not needed -- destroyDisplay internals don't re-lock (private call path)
        sendRemoveMonitor();
        displayCreated_ = false;
        monitor_ = nullptr;
        displayIndex_ = -1;
    }

    // Open driver device if not already open
    if (deviceHandle_ == INVALID_HANDLE_VALUE) {
        if (!openDriverDevice()) {
            log("VirtualDisplayManager: failed to open driver device. "
                "Is the IddCx virtual display driver installed?");
            return false;
        }
    }

    // Snapshot current monitors so we can diff after adding
    std::vector<HMONITOR> monitorsBefore = enumerateMonitors();

    // Send IOCTL to add the monitor
    if (!sendAddMonitor(width, height, refreshRate)) {
        log("VirtualDisplayManager: IOCTL_ADD_MONITOR failed");
        return false;
    }

    // Wait for Windows to detect the new display.
    // This mirrors the macOS behaviour which also waits ~500ms.
    constexpr int maxRetries = 10;
    constexpr int retryDelayMs = 200;
    HMONITOR newMonitor = nullptr;

    for (int i = 0; i < maxRetries; ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(retryDelayMs));
        newMonitor = findNewMonitor(monitorsBefore);
        if (newMonitor != nullptr) {
            break;
        }
    }

    if (newMonitor == nullptr) {
        log("VirtualDisplayManager: new monitor not detected after adding. "
            "The driver may have failed to create the display.");
        // Try to clean up
        sendRemoveMonitor();
        return false;
    }

    // Store state
    monitor_ = newMonitor;
    displayIndex_ = findDisplayIndex(newMonitor);
    width_ = width;
    height_ = height;
    refreshRate_ = refreshRate;
    displayCreated_ = true;

    log("VirtualDisplayManager: virtual display created %dx%d @ %dHz (displayIndex=%d)",
        width, height, refreshRate, displayIndex_);

    return true;
}

void VirtualDisplayManager::destroyDisplay() {
    std::lock_guard<std::mutex> lock(mutex_);

    if (!displayCreated_) {
        return;
    }

    // Save position before destroying so we can restore next time
    // (call the non-locking internals directly since we hold the lock)
    // We write registry directly here to avoid deadlock with public savePosition()
    if (monitor_ != nullptr) {
        MONITORINFO mi = {};
        mi.cbSize = sizeof(mi);
        if (GetMonitorInfoW(monitor_, &mi)) {
            int x = mi.rcMonitor.left;
            int y = mi.rcMonitor.top;
            writeRegistryDword(L"DisplayPositionX", static_cast<DWORD>(x));
            writeRegistryDword(L"DisplayPositionY", static_cast<DWORD>(y));
            writeRegistryDword(L"HasPosition", 1);
            log("VirtualDisplayManager: saved position (%d, %d) before destroy", x, y);
        }
    }

    sendRemoveMonitor();

    displayCreated_ = false;
    monitor_ = nullptr;
    displayIndex_ = -1;
    width_ = 0;
    height_ = 0;
    refreshRate_ = 0;

    log("VirtualDisplayManager: virtual display destroyed");
}

bool VirtualDisplayManager::isDisplayCreated() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return displayCreated_;
}

int VirtualDisplayManager::displayIndex() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return displayIndex_;
}

HMONITOR VirtualDisplayManager::monitorHandle() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return monitor_;
}

void VirtualDisplayManager::savePosition() {
    std::lock_guard<std::mutex> lock(mutex_);

    if (!displayCreated_ || monitor_ == nullptr) {
        log("VirtualDisplayManager::savePosition: no active display");
        return;
    }

    MONITORINFO mi = {};
    mi.cbSize = sizeof(mi);
    if (!GetMonitorInfoW(monitor_, &mi)) {
        log("VirtualDisplayManager::savePosition: GetMonitorInfo failed (err=%lu)",
            GetLastError());
        return;
    }

    int x = mi.rcMonitor.left;
    int y = mi.rcMonitor.top;

    writeRegistryDword(L"DisplayPositionX", static_cast<DWORD>(x));
    writeRegistryDword(L"DisplayPositionY", static_cast<DWORD>(y));
    writeRegistryDword(L"HasPosition", 1);

    log("VirtualDisplayManager: saved display position (%d, %d)", x, y);
}

void VirtualDisplayManager::restorePosition() {
    std::lock_guard<std::mutex> lock(mutex_);

    if (!displayCreated_ || monitor_ == nullptr) {
        log("VirtualDisplayManager::restorePosition: no active display");
        return;
    }

    DWORD hasPosition = 0;
    if (!readRegistryDword(L"HasPosition", hasPosition) || hasPosition == 0) {
        log("VirtualDisplayManager::restorePosition: no saved position found");
        return;
    }

    DWORD posX = 0, posY = 0;
    if (!readRegistryDword(L"DisplayPositionX", posX) ||
        !readRegistryDword(L"DisplayPositionY", posY)) {
        log("VirtualDisplayManager::restorePosition: failed to read saved position");
        return;
    }

    int x = static_cast<int>(posX);
    int y = static_cast<int>(posY);

    if (setDisplayPosition(x, y)) {
        log("VirtualDisplayManager: restored display position (%d, %d)", x, y);
    } else {
        log("VirtualDisplayManager: failed to restore display position (%d, %d)", x, y);
    }
}

bool VirtualDisplayManager::isDriverInstalled() const {
    // Try to find the device interface to check if the driver is present.
    HDEVINFO devInfo = SetupDiGetClassDevsW(
        &GUID_VIRTUAL_DISPLAY_DRIVER,
        nullptr,
        nullptr,
        DIGCF_DEVICEINTERFACE | DIGCF_PRESENT);

    if (devInfo == INVALID_HANDLE_VALUE) {
        return false;
    }

    SP_DEVICE_INTERFACE_DATA ifData = {};
    ifData.cbSize = sizeof(ifData);

    BOOL found = SetupDiEnumDeviceInterfaces(
        devInfo, nullptr, &GUID_VIRTUAL_DISPLAY_DRIVER, 0, &ifData);

    SetupDiDestroyDeviceInfoList(devInfo);
    return found == TRUE;
}

// ---------------------------------------------------------------------------
// Driver Communication
// ---------------------------------------------------------------------------

bool VirtualDisplayManager::openDriverDevice() {
    // Enumerate device interfaces matching our GUID
    HDEVINFO devInfo = SetupDiGetClassDevsW(
        &GUID_VIRTUAL_DISPLAY_DRIVER,
        nullptr,
        nullptr,
        DIGCF_DEVICEINTERFACE | DIGCF_PRESENT);

    if (devInfo == INVALID_HANDLE_VALUE) {
        log("VirtualDisplayManager: SetupDiGetClassDevs failed (err=%lu)", GetLastError());
        return false;
    }

    // Get the first device interface
    SP_DEVICE_INTERFACE_DATA ifData = {};
    ifData.cbSize = sizeof(ifData);

    if (!SetupDiEnumDeviceInterfaces(devInfo, nullptr, &GUID_VIRTUAL_DISPLAY_DRIVER, 0, &ifData)) {
        log("VirtualDisplayManager: no device interface found for virtual display driver "
            "(err=%lu). Is the driver installed?", GetLastError());
        SetupDiDestroyDeviceInfoList(devInfo);
        return false;
    }

    // Get required buffer size for interface detail
    DWORD requiredSize = 0;
    SetupDiGetDeviceInterfaceDetailW(devInfo, &ifData, nullptr, 0, &requiredSize, nullptr);

    if (requiredSize == 0) {
        log("VirtualDisplayManager: failed to get interface detail size (err=%lu)", GetLastError());
        SetupDiDestroyDeviceInfoList(devInfo);
        return false;
    }

    // Allocate and retrieve the detail data
    std::vector<uint8_t> detailBuf(requiredSize);
    auto* detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(detailBuf.data());
    detail->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W);

    if (!SetupDiGetDeviceInterfaceDetailW(devInfo, &ifData, detail, requiredSize, nullptr, nullptr)) {
        log("VirtualDisplayManager: SetupDiGetDeviceInterfaceDetail failed (err=%lu)",
            GetLastError());
        SetupDiDestroyDeviceInfoList(devInfo);
        return false;
    }

    // Open the device
    deviceHandle_ = CreateFileW(
        detail->DevicePath,
        GENERIC_READ | GENERIC_WRITE,
        0,          // no sharing
        nullptr,    // default security
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        nullptr);

    SetupDiDestroyDeviceInfoList(devInfo);

    if (deviceHandle_ == INVALID_HANDLE_VALUE) {
        log("VirtualDisplayManager: CreateFile failed for device path (err=%lu)", GetLastError());
        return false;
    }

    log("VirtualDisplayManager: driver device opened successfully");
    return true;
}

void VirtualDisplayManager::closeDriverDevice() {
    if (deviceHandle_ != INVALID_HANDLE_VALUE) {
        CloseHandle(deviceHandle_);
        deviceHandle_ = INVALID_HANDLE_VALUE;
        log("VirtualDisplayManager: driver device closed");
    }
}

bool VirtualDisplayManager::sendAddMonitor(int width, int height, int refreshRate) {
    if (deviceHandle_ == INVALID_HANDLE_VALUE) {
        return false;
    }

    AddMonitorRequest req = {};
    req.width = static_cast<uint32_t>(width);
    req.height = static_cast<uint32_t>(height);
    req.refreshRate = static_cast<uint32_t>(refreshRate);

    DWORD bytesReturned = 0;
    DWORD outputIndex = 0;

    BOOL success = DeviceIoControl(
        deviceHandle_,
        IOCTL_ADD_MONITOR,
        &req, sizeof(req),
        &outputIndex, sizeof(outputIndex),
        &bytesReturned,
        nullptr);

    if (!success) {
        log("VirtualDisplayManager: DeviceIoControl(ADD_MONITOR) failed (err=%lu)",
            GetLastError());
        return false;
    }

    // The driver may return the monitor index it assigned
    if (bytesReturned >= sizeof(DWORD)) {
        driverMonitorIndex_ = outputIndex;
        log("VirtualDisplayManager: driver assigned monitor index %u", driverMonitorIndex_);
    } else {
        driverMonitorIndex_ = 0;
    }

    return true;
}

bool VirtualDisplayManager::sendRemoveMonitor() {
    if (deviceHandle_ == INVALID_HANDLE_VALUE) {
        return false;
    }

    RemoveMonitorRequest req = {};
    req.monitorIndex = driverMonitorIndex_;

    DWORD bytesReturned = 0;

    BOOL success = DeviceIoControl(
        deviceHandle_,
        IOCTL_REMOVE_MONITOR,
        &req, sizeof(req),
        nullptr, 0,
        &bytesReturned,
        nullptr);

    if (!success) {
        log("VirtualDisplayManager: DeviceIoControl(REMOVE_MONITOR) failed (err=%lu)",
            GetLastError());
        return false;
    }

    log("VirtualDisplayManager: monitor removed (driverIndex=%u)", driverMonitorIndex_);
    return true;
}

// ---------------------------------------------------------------------------
// Monitor Enumeration & Detection
// ---------------------------------------------------------------------------

std::vector<HMONITOR> VirtualDisplayManager::enumerateMonitors() const {
    std::vector<HMONITOR> monitors;
    EnumDisplayMonitors(nullptr, nullptr, collectMonitorsProc, reinterpret_cast<LPARAM>(&monitors));
    return monitors;
}

HMONITOR VirtualDisplayManager::findNewMonitor(const std::vector<HMONITOR>& previousMonitors) const {
    std::vector<HMONITOR> currentMonitors = enumerateMonitors();

    for (HMONITOR current : currentMonitors) {
        bool existed = false;
        for (HMONITOR prev : previousMonitors) {
            if (current == prev) {
                existed = true;
                break;
            }
        }
        if (!existed) {
            return current;
        }
    }

    return nullptr;
}

int VirtualDisplayManager::findDisplayIndex(HMONITOR monitor) const {
    if (monitor == nullptr) {
        return -1;
    }

    // Enumerate DXGI adapters and outputs to find the matching output index
    ComPtr<IDXGIFactory1> factory;
    HRESULT hr = CreateDXGIFactory1(__uuidof(IDXGIFactory1),
                                     reinterpret_cast<void**>(factory.GetAddressOf()));
    if (FAILED(hr)) {
        log("VirtualDisplayManager: CreateDXGIFactory1 failed (hr=0x%08lx)", hr);
        return -1;
    }

    int globalIndex = 0;

    for (UINT adapterIdx = 0; ; ++adapterIdx) {
        ComPtr<IDXGIAdapter1> adapter;
        hr = factory->EnumAdapters1(adapterIdx, adapter.GetAddressOf());
        if (hr == DXGI_ERROR_NOT_FOUND) {
            break;
        }
        if (FAILED(hr)) {
            continue;
        }

        for (UINT outputIdx = 0; ; ++outputIdx) {
            ComPtr<IDXGIOutput> output;
            hr = adapter->EnumOutputs(outputIdx, output.GetAddressOf());
            if (hr == DXGI_ERROR_NOT_FOUND) {
                break;
            }
            if (FAILED(hr)) {
                ++globalIndex;
                continue;
            }

            DXGI_OUTPUT_DESC desc = {};
            if (SUCCEEDED(output->GetDesc(&desc))) {
                if (desc.Monitor == monitor) {
                    return globalIndex;
                }
            }
            ++globalIndex;
        }
    }

    log("VirtualDisplayManager: could not find DXGI output for monitor handle %p", monitor);
    return -1;
}

// ---------------------------------------------------------------------------
// Display Positioning
// ---------------------------------------------------------------------------

bool VirtualDisplayManager::setDisplayPosition(int x, int y) {
    // Find the device name for our virtual monitor
    if (monitor_ == nullptr) {
        return false;
    }

    MONITORINFOEXW mi = {};
    mi.cbSize = sizeof(mi);
    if (!GetMonitorInfoW(monitor_, &mi)) {
        log("VirtualDisplayManager::setDisplayPosition: GetMonitorInfo failed (err=%lu)",
            GetLastError());
        return false;
    }

    // Get current display settings for this device
    DEVMODEW dm = {};
    dm.dmSize = sizeof(dm);
    if (!EnumDisplaySettingsW(mi.szDevice, ENUM_CURRENT_SETTINGS, &dm)) {
        log("VirtualDisplayManager::setDisplayPosition: EnumDisplaySettings failed (err=%lu)",
            GetLastError());
        return false;
    }

    // Update position
    dm.dmPosition.x = x;
    dm.dmPosition.y = y;
    dm.dmFields = DM_POSITION;

    LONG result = ChangeDisplaySettingsExW(
        mi.szDevice,
        &dm,
        nullptr,
        CDS_UPDATEREGISTRY | CDS_NORESET,
        nullptr);

    if (result != DISP_CHANGE_SUCCESSFUL) {
        log("VirtualDisplayManager::setDisplayPosition: ChangeDisplaySettingsEx failed (%ld)",
            result);
        return false;
    }

    // Apply the change globally
    ChangeDisplaySettingsExW(nullptr, nullptr, nullptr, 0, nullptr);

    return true;
}

// ---------------------------------------------------------------------------
// Registry Persistence
// ---------------------------------------------------------------------------

bool VirtualDisplayManager::readRegistryDword(const wchar_t* valueName, DWORD& outValue) const {
    HKEY hKey = nullptr;
    LONG result = RegOpenKeyExW(HKEY_CURRENT_USER, REGISTRY_KEY_PATH, 0, KEY_READ, &hKey);
    if (result != ERROR_SUCCESS) {
        return false;
    }

    DWORD type = 0;
    DWORD size = sizeof(DWORD);
    result = RegQueryValueExW(hKey, valueName, nullptr, &type,
                              reinterpret_cast<BYTE*>(&outValue), &size);

    RegCloseKey(hKey);

    return (result == ERROR_SUCCESS && type == REG_DWORD);
}

bool VirtualDisplayManager::writeRegistryDword(const wchar_t* valueName, DWORD value) const {
    HKEY hKey = nullptr;
    DWORD disposition = 0;

    LONG result = RegCreateKeyExW(
        HKEY_CURRENT_USER,
        REGISTRY_KEY_PATH,
        0,
        nullptr,
        REG_OPTION_NON_VOLATILE,
        KEY_WRITE,
        nullptr,
        &hKey,
        &disposition);

    if (result != ERROR_SUCCESS) {
        log("VirtualDisplayManager: RegCreateKeyEx failed (err=%ld)", result);
        return false;
    }

    result = RegSetValueExW(hKey, valueName, 0, REG_DWORD,
                            reinterpret_cast<const BYTE*>(&value), sizeof(value));

    RegCloseKey(hKey);

    return (result == ERROR_SUCCESS);
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

void VirtualDisplayManager::log(const char* fmt, ...) {
    char buf[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);

    // Output to debugger (visible in Visual Studio / DebugView)
    OutputDebugStringA(buf);
    OutputDebugStringA("\n");

    // Also output to stderr for console builds
    fprintf(stderr, "%s\n", buf);
}
