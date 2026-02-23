#include "AdbManager.h"
#include <cstdio>
#include <cstring>
#include <sstream>
#include <vector>
#include <algorithm>

// ============================================================================
// Construction
// ============================================================================

AdbManager::AdbManager() {
    // Attempt to find ADB immediately on construction
    adbPath_ = searchAdbLocations();
    if (!adbPath_.empty()) {
        printf("[AdbManager] Found ADB at: %s\n", adbPath_.c_str());
    } else {
        printf("[AdbManager] ADB not found\n");
    }
}

// ============================================================================
// Public API
// ============================================================================

std::string AdbManager::findAdb() {
    if (adbPath_.empty()) {
        adbPath_ = searchAdbLocations();
    }
    return adbPath_;
}

bool AdbManager::setupReverse(uint16_t port) {
    if (adbPath_.empty()) {
        printf("[AdbManager] Cannot setup reverse: ADB not found\n");
        return false;
    }

    if (!isDeviceConnected()) {
        printf("[AdbManager] Cannot setup reverse: no device connected\n");
        return false;
    }

    // adb reverse tcp:PORT tcp:PORT
    std::string cmd = "\"" + adbPath_ + "\" reverse tcp:"
                      + std::to_string(port) + " tcp:" + std::to_string(port);

    int exitCode = runCommandStatus(cmd);
    if (exitCode == 0) {
        printf("[AdbManager] Reverse port forwarding set up: tcp:%u -> tcp:%u\n",
               port, port);
        return true;
    }

    printf("[AdbManager] Failed to setup reverse (exit code: %d)\n", exitCode);
    return false;
}

bool AdbManager::removeReverse(uint16_t port) {
    if (adbPath_.empty()) {
        printf("[AdbManager] Cannot remove reverse: ADB not found\n");
        return false;
    }

    // adb reverse --remove tcp:PORT
    std::string cmd = "\"" + adbPath_ + "\" reverse --remove tcp:"
                      + std::to_string(port);

    int exitCode = runCommandStatus(cmd);
    if (exitCode == 0) {
        printf("[AdbManager] Reverse port forwarding removed for tcp:%u\n", port);
        return true;
    }

    printf("[AdbManager] Failed to remove reverse (exit code: %d)\n", exitCode);
    return false;
}

bool AdbManager::isDeviceConnected() {
    if (adbPath_.empty()) {
        return false;
    }

    std::string cmd = "\"" + adbPath_ + "\" devices";
    std::string output = runCommand(cmd);

    if (output.empty()) {
        return false;
    }

    // Parse "adb devices" output:
    //   List of devices attached
    //   SERIAL\tdevice
    //   SERIAL\toffline
    //   SERIAL\tunauthorized
    //
    // We look for lines with a tab followed by "device" (meaning ready).
    std::istringstream stream(output);
    std::string line;
    while (std::getline(stream, line)) {
        // Skip the header line
        if (line.find("List of") != std::string::npos) {
            continue;
        }
        // Skip empty lines
        if (line.empty() || line[0] == '\r' || line[0] == '\n') {
            continue;
        }
        // A connected device line contains a tab followed by "device"
        size_t tabPos = line.find('\t');
        if (tabPos != std::string::npos) {
            std::string status = line.substr(tabPos + 1);
            // Trim whitespace/carriage returns
            while (!status.empty() && (status.back() == '\r' ||
                   status.back() == '\n' || status.back() == ' ')) {
                status.pop_back();
            }
            if (status == "device") {
                return true;
            }
        }
    }

    return false;
}

std::string AdbManager::deviceSerial() {
    if (adbPath_.empty()) {
        return "";
    }

    std::string cmd = "\"" + adbPath_ + "\" devices";
    std::string output = runCommand(cmd);

    if (output.empty()) {
        return "";
    }

    // Return the serial of the first device with status "device"
    std::istringstream stream(output);
    std::string line;
    while (std::getline(stream, line)) {
        if (line.find("List of") != std::string::npos) {
            continue;
        }
        if (line.empty() || line[0] == '\r' || line[0] == '\n') {
            continue;
        }
        size_t tabPos = line.find('\t');
        if (tabPos != std::string::npos) {
            std::string status = line.substr(tabPos + 1);
            while (!status.empty() && (status.back() == '\r' ||
                   status.back() == '\n' || status.back() == ' ')) {
                status.pop_back();
            }
            if (status == "device") {
                return line.substr(0, tabPos);
            }
        }
    }

    return "";
}

// ============================================================================
// ADB search
// ============================================================================

std::string AdbManager::searchAdbLocations() {
    // 1. Bundled: same directory as the running executable
    {
        char exePath[MAX_PATH];
        DWORD len = GetModuleFileNameA(nullptr, exePath, MAX_PATH);
        if (len > 0 && len < MAX_PATH) {
            std::string dir(exePath);
            size_t lastSlash = dir.find_last_of("\\/");
            if (lastSlash != std::string::npos) {
                std::string bundled = dir.substr(0, lastSlash + 1) + "adb.exe";
                if (fileExists(bundled)) {
                    printf("[AdbManager] Found bundled ADB: %s\n", bundled.c_str());
                    return bundled;
                }
            }
        }
    }

    // 2. Android SDK via LOCALAPPDATA
    {
        char localAppData[MAX_PATH];
        DWORD len = GetEnvironmentVariableA("LOCALAPPDATA", localAppData, MAX_PATH);
        if (len > 0 && len < MAX_PATH) {
            std::string sdkPath = std::string(localAppData)
                + "\\Android\\Sdk\\platform-tools\\adb.exe";
            if (fileExists(sdkPath)) {
                printf("[AdbManager] Found Android SDK ADB: %s\n", sdkPath.c_str());
                return sdkPath;
            }
        }
    }

    // 3. System PATH
    {
        std::string pathResult = findInPath("adb.exe");
        if (!pathResult.empty()) {
            printf("[AdbManager] Found ADB in PATH: %s\n", pathResult.c_str());
            return pathResult;
        }
    }

    return "";
}

bool AdbManager::fileExists(const std::string& path) {
    DWORD attrs = GetFileAttributesA(path.c_str());
    return (attrs != INVALID_FILE_ATTRIBUTES) &&
           !(attrs & FILE_ATTRIBUTE_DIRECTORY);
}

std::string AdbManager::findInPath(const std::string& exeName) {
    // Use SearchPathA which searches the system PATH
    char foundPath[MAX_PATH];
    DWORD result = SearchPathA(
        nullptr,            // Use default search path (system PATH)
        exeName.c_str(),    // File to find
        nullptr,            // Extension (already included)
        MAX_PATH,           // Buffer size
        foundPath,          // Output buffer
        nullptr             // Pointer to filename component (not needed)
    );

    if (result > 0 && result < MAX_PATH) {
        return std::string(foundPath);
    }

    return "";
}

// ============================================================================
// Command execution via CreateProcess + pipes
// ============================================================================

std::string AdbManager::runCommand(const std::string& cmd) {
    // Set up security attributes to allow handle inheritance
    SECURITY_ATTRIBUTES sa;
    sa.nLength = sizeof(SECURITY_ATTRIBUTES);
    sa.bInheritHandle = TRUE;
    sa.lpSecurityDescriptor = nullptr;

    // Create pipe for stdout capture
    HANDLE hReadPipe = nullptr;
    HANDLE hWritePipe = nullptr;
    if (!CreatePipe(&hReadPipe, &hWritePipe, &sa, 0)) {
        printf("[AdbManager] CreatePipe failed: %lu\n", GetLastError());
        return "";
    }

    // Ensure the read handle is NOT inherited by the child process
    SetHandleInformation(hReadPipe, HANDLE_FLAG_INHERIT, 0);

    // Set up startup info to redirect stdout and stderr to our pipe
    STARTUPINFOA si;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    si.hStdOutput = hWritePipe;
    si.hStdError = hWritePipe;
    si.hStdInput = nullptr;
    si.dwFlags |= STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE; // Hide the console window

    PROCESS_INFORMATION pi;
    ZeroMemory(&pi, sizeof(pi));

    // CreateProcess requires a mutable command line buffer
    std::vector<char> cmdBuf(cmd.begin(), cmd.end());
    cmdBuf.push_back('\0');

    BOOL created = CreateProcessA(
        nullptr,            // Application name (use command line)
        cmdBuf.data(),      // Command line (mutable)
        nullptr,            // Process security attributes
        nullptr,            // Thread security attributes
        TRUE,               // Inherit handles
        CREATE_NO_WINDOW,   // Don't create a console window
        nullptr,            // Use parent environment
        nullptr,            // Use parent working directory
        &si,                // Startup info
        &pi                 // Process info (output)
    );

    // Close the write end of the pipe in the parent immediately.
    // This is critical so that ReadFile will get EOF when the child exits.
    CloseHandle(hWritePipe);

    if (!created) {
        printf("[AdbManager] CreateProcess failed for '%s': %lu\n",
               cmd.c_str(), GetLastError());
        CloseHandle(hReadPipe);
        return "";
    }

    // Read stdout from the pipe with timeout awareness
    std::string output;
    char buffer[4096];
    DWORD bytesRead = 0;

    // Wait for process to complete (with timeout), then read all output
    DWORD waitResult = WaitForSingleObject(pi.hProcess, COMMAND_TIMEOUT_MS);

    if (waitResult == WAIT_TIMEOUT) {
        printf("[AdbManager] Command timed out: %s\n", cmd.c_str());
        TerminateProcess(pi.hProcess, 1);
        CloseHandle(hReadPipe);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        return "";
    }

    // Process finished, read all available output
    while (ReadFile(hReadPipe, buffer, sizeof(buffer) - 1, &bytesRead, nullptr)
           && bytesRead > 0) {
        buffer[bytesRead] = '\0';
        output.append(buffer, bytesRead);
    }

    CloseHandle(hReadPipe);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);

    return output;
}

int AdbManager::runCommandStatus(const std::string& cmd) {
    // Set up security attributes
    SECURITY_ATTRIBUTES sa;
    sa.nLength = sizeof(SECURITY_ATTRIBUTES);
    sa.bInheritHandle = TRUE;
    sa.lpSecurityDescriptor = nullptr;

    // Create a pipe to capture output (even if we discard it),
    // so the child process doesn't block on a full stdout buffer
    HANDLE hReadPipe = nullptr;
    HANDLE hWritePipe = nullptr;
    if (!CreatePipe(&hReadPipe, &hWritePipe, &sa, 0)) {
        printf("[AdbManager] CreatePipe failed: %lu\n", GetLastError());
        return -1;
    }

    SetHandleInformation(hReadPipe, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOA si;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    si.hStdOutput = hWritePipe;
    si.hStdError = hWritePipe;
    si.hStdInput = nullptr;
    si.dwFlags |= STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;

    PROCESS_INFORMATION pi;
    ZeroMemory(&pi, sizeof(pi));

    std::vector<char> cmdBuf(cmd.begin(), cmd.end());
    cmdBuf.push_back('\0');

    BOOL created = CreateProcessA(
        nullptr,
        cmdBuf.data(),
        nullptr,
        nullptr,
        TRUE,
        CREATE_NO_WINDOW,
        nullptr,
        nullptr,
        &si,
        &pi
    );

    CloseHandle(hWritePipe);

    if (!created) {
        printf("[AdbManager] CreateProcess failed for '%s': %lu\n",
               cmd.c_str(), GetLastError());
        CloseHandle(hReadPipe);
        return -1;
    }

    // Wait for process to complete, then drain pipe afterward.
    // Note: pipe buffer (default 4KB) is sufficient for ADB command output.
    // If the child fills the pipe and blocks, WaitForSingleObject will
    // time out and we terminate the child.
    DWORD waitResult = WaitForSingleObject(pi.hProcess, COMMAND_TIMEOUT_MS);

    if (waitResult == WAIT_TIMEOUT) {
        printf("[AdbManager] Command timed out: %s\n", cmd.c_str());
        TerminateProcess(pi.hProcess, 1);
        CloseHandle(hReadPipe);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        return -1;
    }

    // Drain remaining pipe data to avoid resource leaks
    {
        char discard[4096];
        DWORD bytesRead = 0;
        while (ReadFile(hReadPipe, discard, sizeof(discard), &bytesRead, nullptr)
               && bytesRead > 0) {
            // discard
        }
    }

    DWORD exitCode = 0;
    GetExitCodeProcess(pi.hProcess, &exitCode);

    CloseHandle(hReadPipe);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);

    return static_cast<int>(exitCode);
}
