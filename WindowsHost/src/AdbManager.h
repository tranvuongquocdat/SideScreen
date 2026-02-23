#pragma once

#include <cstdint>
#include <string>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

class AdbManager {
public:
    AdbManager();

    // Find adb executable, returns path or empty string
    std::string findAdb();

    // Set up reverse port forwarding: adb reverse tcp:PORT tcp:PORT
    bool setupReverse(uint16_t port);

    // Remove reverse port forwarding
    bool removeReverse(uint16_t port);

    // Check if any Android device is connected via USB
    bool isDeviceConnected();

    // Get connected device serial (first device if multiple)
    std::string deviceSerial();

    // Get the resolved ADB path (empty if not found)
    std::string adbPath() const { return adbPath_; }

private:
    // Run a command and capture stdout. Returns stdout content.
    // Empty string on failure or timeout.
    std::string runCommand(const std::string& cmd);

    // Run a command and return exit code (-1 on failure/timeout)
    int runCommandStatus(const std::string& cmd);

    // Search for adb.exe in common locations
    std::string searchAdbLocations();

    // Check if a file exists at the given path
    static bool fileExists(const std::string& path);

    // Search PATH environment variable for an executable
    static std::string findInPath(const std::string& exeName);

    std::string adbPath_;

    // Timeout for ADB commands in milliseconds
    static constexpr DWORD COMMAND_TIMEOUT_MS = 5000;
};
