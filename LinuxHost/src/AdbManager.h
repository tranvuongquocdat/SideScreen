#pragma once

#include <string>
#include <cstdint>
#include <vector>

/**
 * AdbManager -- locate and interact with the Android Debug Bridge (adb).
 *
 * ADB search order (Linux):
 *   1. Bundled:    ./adb  (same directory as the running binary)
 *   2. Android SDK: $HOME/Android/Sdk/platform-tools/adb
 *   3. System PATH: search each directory in $PATH
 *
 * All commands use fork/exec + pipe (no system()) with a 5-second timeout.
 */
class AdbManager {
public:
    AdbManager();
    ~AdbManager() = default;

    // Non-copyable
    AdbManager(const AdbManager&) = delete;
    AdbManager& operator=(const AdbManager&) = delete;

    /**
     * Locate the adb binary.
     * Searches in priority order and caches the result.
     * @return Full path to adb, or empty string if not found.
     */
    std::string findAdb();

    /**
     * Set up adb reverse port forwarding:
     *   adb reverse tcp:<port> tcp:<port>
     * @return true on success
     */
    bool setupReverse(uint16_t port);

    /**
     * Remove a previously set up reverse forwarding:
     *   adb reverse --remove tcp:<port>
     * @return true on success
     */
    bool removeReverse(uint16_t port);

    /**
     * Check if at least one USB/TCP device is connected.
     * Parses the output of "adb devices".
     * @return true if a device is listed as "device" (authorized)
     */
    bool isDeviceConnected();

    /**
     * Get the serial number of the first connected device.
     * @return Device serial string, or empty if no device.
     */
    std::string deviceSerial();

private:
    // ----- search helpers ----------------------------------------------------
    std::string findBundledAdb();
    std::string findSdkAdb();
    std::string findPathAdb();

    /** Return the directory containing the current executable. */
    std::string executableDir();

    /** Check if a file exists and is executable. */
    static bool isExecutable(const std::string& path);

    // ----- process helpers ---------------------------------------------------

    /**
     * Run a command, capture stdout.
     * Uses fork/exec + pipe with 5-second timeout.
     * Returns empty string on failure/timeout.
     */
    std::string runCommand(const std::string& cmd);

    /**
     * Run a command and return exit status.
     * Uses fork/exec with 5-second timeout.
     * Returns -1 on error/timeout.
     */
    int runCommandStatus(const std::string& cmd);

    // ----- parsing helpers ---------------------------------------------------

    /**
     * Parse "adb devices" output and return a list of (serial, state) pairs.
     * Only entries with state "device" are considered connected.
     */
    struct DeviceEntry {
        std::string serial;
        std::string state; // "device", "unauthorized", "offline", etc.
    };
    std::vector<DeviceEntry> parseDevices(const std::string& output);

    // ----- state -------------------------------------------------------------
    std::string adbPath_; // cached after first findAdb()
};
