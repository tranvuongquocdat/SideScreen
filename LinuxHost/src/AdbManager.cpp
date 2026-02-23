#include "AdbManager.h"
#include "Config.h"

#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <cstdio>
#include <sstream>
#include <algorithm>

#include <unistd.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <pwd.h>
#include <limits.h>

static constexpr int kCommandTimeoutSec = 5;

// ---------------------------------------------------------------------------
// Lifetime
// ---------------------------------------------------------------------------

AdbManager::AdbManager() = default;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

std::string AdbManager::findAdb() {
    if (!adbPath_.empty()) return adbPath_;

    // 1. Bundled adb
    std::string path = findBundledAdb();
    if (!path.empty()) { adbPath_ = path; return adbPath_; }

    // 2. Android SDK
    path = findSdkAdb();
    if (!path.empty()) { adbPath_ = path; return adbPath_; }

    // 3. System PATH
    path = findPathAdb();
    if (!path.empty()) { adbPath_ = path; return adbPath_; }

    return {};
}

bool AdbManager::setupReverse(uint16_t port) {
    if (findAdb().empty()) return false;

    std::ostringstream cmd;
    cmd << "\"" << adbPath_ << "\" reverse tcp:" << port << " tcp:" << port;
    return runCommandStatus(cmd.str()) == 0;
}

bool AdbManager::removeReverse(uint16_t port) {
    if (findAdb().empty()) return false;

    std::ostringstream cmd;
    cmd << "\"" << adbPath_ << "\" reverse --remove tcp:" << port;
    return runCommandStatus(cmd.str()) == 0;
}

bool AdbManager::isDeviceConnected() {
    if (findAdb().empty()) return false;

    std::string output = runCommand("\"" + adbPath_ + "\" devices");
    if (output.empty()) return false;

    auto devices = parseDevices(output);
    return std::any_of(devices.begin(), devices.end(),
        [](const DeviceEntry& d) { return d.state == "device"; });
}

std::string AdbManager::deviceSerial() {
    if (findAdb().empty()) return {};

    std::string output = runCommand("\"" + adbPath_ + "\" devices");
    if (output.empty()) return {};

    auto devices = parseDevices(output);
    for (const auto& d : devices) {
        if (d.state == "device") return d.serial;
    }
    return {};
}

// ---------------------------------------------------------------------------
// ADB search helpers
// ---------------------------------------------------------------------------

std::string AdbManager::findBundledAdb() {
    std::string dir = executableDir();
    if (dir.empty()) return {};

    std::string path = dir + "/adb";
    if (isExecutable(path)) return path;

    return {};
}

std::string AdbManager::findSdkAdb() {
    const char* home = std::getenv("HOME");
    if (!home || home[0] == '\0') {
        struct passwd* pw = getpwuid(getuid());
        home = pw ? pw->pw_dir : nullptr;
    }
    if (!home) return {};

    // Standard Android SDK location on Linux
    std::string path = std::string(home) + "/Android/Sdk/platform-tools/adb";
    if (isExecutable(path)) return path;

    // Also check ANDROID_HOME / ANDROID_SDK_ROOT
    for (const char* envVar : {"ANDROID_HOME", "ANDROID_SDK_ROOT"}) {
        const char* sdkRoot = std::getenv(envVar);
        if (sdkRoot && sdkRoot[0] != '\0') {
            path = std::string(sdkRoot) + "/platform-tools/adb";
            if (isExecutable(path)) return path;
        }
    }

    return {};
}

std::string AdbManager::findPathAdb() {
    const char* pathEnv = std::getenv("PATH");
    if (!pathEnv || pathEnv[0] == '\0') return {};

    std::istringstream stream(pathEnv);
    std::string dir;
    while (std::getline(stream, dir, ':')) {
        if (dir.empty()) continue;
        std::string path = dir + "/adb";
        if (isExecutable(path)) return path;
    }

    return {};
}

std::string AdbManager::executableDir() {
    // On Linux, /proc/self/exe is a symlink to the running binary
    char buf[PATH_MAX];
    ssize_t len = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (len <= 0) return {};

    buf[len] = '\0';
    std::string exePath(buf);

    auto slash = exePath.rfind('/');
    if (slash == std::string::npos) return ".";
    return exePath.substr(0, slash);
}

bool AdbManager::isExecutable(const std::string& path) {
    struct stat st;
    if (stat(path.c_str(), &st) != 0) return false;
    // Must be a regular file and executable
    return S_ISREG(st.st_mode) && (st.st_mode & S_IXUSR);
}

// ---------------------------------------------------------------------------
// Device list parsing
// ---------------------------------------------------------------------------

std::vector<AdbManager::DeviceEntry> AdbManager::parseDevices(const std::string& output) {
    std::vector<DeviceEntry> result;
    std::istringstream stream(output);
    std::string line;

    while (std::getline(stream, line)) {
        // Skip the header line "List of devices attached"
        if (line.find("List of devices") != std::string::npos) continue;

        // Skip empty lines
        if (line.empty() || line[0] == '\n' || line[0] == '\r') continue;

        // Lines look like:  "SERIAL\tSTATE"
        auto tab = line.find('\t');
        if (tab == std::string::npos) continue;

        DeviceEntry entry;
        entry.serial = line.substr(0, tab);
        entry.state = line.substr(tab + 1);

        // Trim whitespace from state
        while (!entry.state.empty() &&
               (entry.state.back() == '\n' || entry.state.back() == '\r' ||
                entry.state.back() == ' ' || entry.state.back() == '\t')) {
            entry.state.pop_back();
        }

        if (!entry.serial.empty() && !entry.state.empty()) {
            result.push_back(std::move(entry));
        }
    }

    return result;
}

// ---------------------------------------------------------------------------
// Process execution helpers
// ---------------------------------------------------------------------------

std::string AdbManager::runCommand(const std::string& cmd) {
    int pipeFd[2];
    if (pipe(pipeFd) == -1) return {};

    pid_t pid = fork();
    if (pid < 0) {
        close(pipeFd[0]);
        close(pipeFd[1]);
        return {};
    }

    if (pid == 0) {
        // Child
        close(pipeFd[0]);
        dup2(pipeFd[1], STDOUT_FILENO);
        dup2(pipeFd[1], STDERR_FILENO);
        close(pipeFd[1]);

        execl("/bin/sh", "sh", "-c", cmd.c_str(), nullptr);
        _exit(127);
    }

    // Parent
    close(pipeFd[1]);

    // Read all output
    std::string output;
    char buf[4096];
    ssize_t n;
    while ((n = read(pipeFd[0], buf, sizeof(buf))) > 0) {
        output.append(buf, static_cast<size_t>(n));
    }
    close(pipeFd[0]);

    // Wait with timeout (5 seconds, polling every 100ms)
    int status = 0;
    bool exited = false;
    for (int i = 0; i < kCommandTimeoutSec * 10; ++i) {
        pid_t ret = waitpid(pid, &status, WNOHANG);
        if (ret != 0) {
            exited = true;
            break;
        }
        usleep(100'000); // 100ms
    }

    if (!exited) {
        kill(pid, SIGKILL);
        waitpid(pid, &status, 0);
        return {};
    }

    // Trim trailing newline
    while (!output.empty() && (output.back() == '\n' || output.back() == '\r')) {
        output.pop_back();
    }

    return output;
}

int AdbManager::runCommandStatus(const std::string& cmd) {
    pid_t pid = fork();
    if (pid < 0) return -1;

    if (pid == 0) {
        // Child: suppress output
        int devNull = open("/dev/null", O_WRONLY);
        if (devNull >= 0) {
            dup2(devNull, STDOUT_FILENO);
            dup2(devNull, STDERR_FILENO);
            close(devNull);
        }

        execl("/bin/sh", "sh", "-c", cmd.c_str(), nullptr);
        _exit(127);
    }

    // Parent: wait with timeout
    int status = 0;
    for (int i = 0; i < kCommandTimeoutSec * 10; ++i) {
        pid_t ret = waitpid(pid, &status, WNOHANG);
        if (ret != 0) {
            if (WIFEXITED(status)) return WEXITSTATUS(status);
            return -1;
        }
        usleep(100'000); // 100ms
    }

    // Timeout -- kill
    kill(pid, SIGKILL);
    waitpid(pid, &status, 0);
    return -1;
}
