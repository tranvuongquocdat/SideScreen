#include "VirtualDisplayManager.h"
#include "../Config.h"

#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <cstdio>
#include <sstream>
#include <fstream>
#include <algorithm>
#include <regex>
#include <filesystem>

#include <unistd.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <pwd.h>

// ---------------------------------------------------------------------------
// Helpers: fork/exec with pipe (no system())
// ---------------------------------------------------------------------------

static constexpr int kCommandTimeoutSec = 5;

/**
 * Split a command string into argv tokens (basic shell-like splitting).
 * Does NOT handle quoting -- callers use /bin/sh -c for complex commands.
 */
static std::vector<std::string> splitArgs(const std::string& cmd) {
    std::vector<std::string> args;
    std::istringstream iss(cmd);
    std::string tok;
    while (iss >> tok) args.push_back(tok);
    return args;
}

// ---------------------------------------------------------------------------
// VirtualDisplayManager lifetime
// ---------------------------------------------------------------------------

VirtualDisplayManager::VirtualDisplayManager() = default;

VirtualDisplayManager::~VirtualDisplayManager() {
    destroyDisplay();
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

bool VirtualDisplayManager::createDisplay(int width, int height, int refreshRate) {
    if (created_) {
        destroyDisplay();
    }

    width_ = width;
    height_ = height;
    refreshRate_ = refreshRate;

    // Try backends in order of preference
    if (tryXrandrDummy(width, height, refreshRate)) {
        backend_ = Backend::Xrandr;
        created_ = true;
        restorePosition();
        return true;
    }

    if (tryXvfb(width, height, refreshRate)) {
        backend_ = Backend::Xvfb;
        created_ = true;
        return true;
    }

#ifdef HAS_PIPEWIRE
    if (tryPipeWire(width, height, refreshRate)) {
        backend_ = Backend::PipeWire;
        created_ = true;
        return true;
    }
#endif

    return false;
}

void VirtualDisplayManager::destroyDisplay() {
    if (!created_) return;

    switch (backend_) {
    case Backend::Xrandr: {
        // Turn off the output, delete the mode
        if (!outputName_.empty()) {
            runCommandStatus("xrandr --output " + outputName_ + " --off");
        }
        if (!modeName_.empty() && !outputName_.empty()) {
            runCommandStatus("xrandr --delmode " + outputName_ + " \"" + modeName_ + "\"");
            runCommandStatus("xrandr --rmmode \"" + modeName_ + "\"");
        }
        modeName_.clear();
        outputName_.clear();
        break;
    }
    case Backend::Xvfb: {
        if (xvfbPid_ > 0) {
            kill(xvfbPid_, SIGTERM);
            int status = 0;
            // Give it 2 seconds to exit gracefully
            for (int i = 0; i < 20; ++i) {
                pid_t ret = waitpid(xvfbPid_, &status, WNOHANG);
                if (ret != 0) break;
                usleep(100'000); // 100ms
            }
            // Force kill if still alive
            if (waitpid(xvfbPid_, &status, WNOHANG) == 0) {
                kill(xvfbPid_, SIGKILL);
                waitpid(xvfbPid_, &status, 0);
            }
            xvfbPid_ = -1;
        }
        xvfbDisplay_.clear();
        break;
    }
    case Backend::PipeWire:
        // PipeWire virtual monitor cleanup would go here
        break;
    case Backend::None:
        break;
    }

    backend_ = Backend::None;
    created_ = false;
}

bool VirtualDisplayManager::isDisplayCreated() const {
    return created_;
}

std::string VirtualDisplayManager::displayName() const {
    switch (backend_) {
    case Backend::Xrandr:  return outputName_;
    case Backend::Xvfb:    return xvfbDisplay_;
    case Backend::PipeWire: return "pipewire-virtual";
    case Backend::None:    break;
    }
    return {};
}

int VirtualDisplayManager::displayIndex() const {
    if (!created_) return -1;

    switch (backend_) {
    case Backend::Xrandr:
        return resolveDisplayIndex(outputName_);
    case Backend::Xvfb:
        // Xvfb is a separate X display, index 0 within that display
        return 0;
    case Backend::PipeWire:
        return 0;
    case Backend::None:
        break;
    }
    return -1;
}

// ---------------------------------------------------------------------------
// Position persistence
// ---------------------------------------------------------------------------

void VirtualDisplayManager::savePosition() {
    if (!created_ || backend_ != Backend::Xrandr || outputName_.empty())
        return;

    // Parse current position from xrandr --query
    std::string xrandrOut = runCommand("xrandr --query");
    if (xrandrOut.empty()) return;

    // Look for our output line: "VIRTUAL1 connected 1920x1200+3840+0 ..."
    std::regex posRegex(outputName_ + R"(\s+connected\s+\d+x\d+\+(\d+)\+(\d+))");
    std::smatch match;
    if (!std::regex_search(xrandrOut, match, posRegex) || match.size() < 3)
        return;

    std::string posX = match[1].str();
    std::string posY = match[2].str();

    // Ensure config directory exists
    std::string dir = configDir();
    std::filesystem::create_directories(dir);

    // Write key=value file
    std::ofstream ofs(positionFilePath());
    if (!ofs) return;

    ofs << "output=" << outputName_ << "\n";
    ofs << "pos_x=" << posX << "\n";
    ofs << "pos_y=" << posY << "\n";
    ofs << "width=" << width_ << "\n";
    ofs << "height=" << height_ << "\n";
    ofs << "refresh=" << refreshRate_ << "\n";
}

void VirtualDisplayManager::restorePosition() {
    if (!created_ || backend_ != Backend::Xrandr || outputName_.empty())
        return;

    std::ifstream ifs(positionFilePath());
    if (!ifs) return;

    std::string line;
    std::string posX, posY, savedOutput;
    while (std::getline(ifs, line)) {
        auto eq = line.find('=');
        if (eq == std::string::npos) continue;
        std::string key = line.substr(0, eq);
        std::string val = line.substr(eq + 1);
        if (key == "output")  savedOutput = val;
        else if (key == "pos_x") posX = val;
        else if (key == "pos_y") posY = val;
    }

    // Only restore if the output name matches what we created
    if (savedOutput != outputName_ || posX.empty() || posY.empty())
        return;

    runCommandStatus("xrandr --output " + outputName_ +
                     " --pos " + posX + "x" + posY);
}

std::string VirtualDisplayManager::configDir() const {
    // Prefer XDG_CONFIG_HOME, fall back to ~/.config
    const char* xdg = std::getenv("XDG_CONFIG_HOME");
    if (xdg && xdg[0] != '\0') {
        return std::string(xdg) + "/sidescreen";
    }

    const char* home = std::getenv("HOME");
    if (!home || home[0] == '\0') {
        struct passwd* pw = getpwuid(getuid());
        home = pw ? pw->pw_dir : "/tmp";
    }
    return std::string(home) + "/.config/sidescreen";
}

std::string VirtualDisplayManager::positionFilePath() const {
    return configDir() + "/display_position";
}

// ---------------------------------------------------------------------------
// Backend 1: xrandr dummy output
// ---------------------------------------------------------------------------

bool VirtualDisplayManager::tryXrandrDummy(int width, int height, int refreshRate) {
    // 1. Find an unused/disconnected output
    outputName_ = findUnusedOutput();
    if (outputName_.empty()) return false;

    // 2. Compute modeline via cvt
    std::string modeline = computeModeline(width, height, refreshRate);
    if (modeline.empty()) return false;

    // Parse modeline: cvt outputs something like:
    //   Modeline "1920x1200_120.00"  ...clock...  ...timings...
    // We need the mode name and the rest.
    auto pos = modeline.find("Modeline");
    if (pos == std::string::npos) return false;
    modeline = modeline.substr(pos + 9); // skip "Modeline "

    // Extract the quoted mode name
    auto q1 = modeline.find('"');
    auto q2 = modeline.find('"', q1 + 1);
    if (q1 == std::string::npos || q2 == std::string::npos) return false;

    modeName_ = modeline.substr(q1 + 1, q2 - q1 - 1);
    std::string modeParams = modeline.substr(q2 + 1);

    // Trim leading whitespace from modeParams
    auto start = modeParams.find_first_not_of(" \t\n\r");
    if (start != std::string::npos)
        modeParams = modeParams.substr(start);

    // 3. Create the mode
    int rc = runCommandStatus("xrandr --newmode \"" + modeName_ + "\" " + modeParams);
    if (rc != 0) {
        // Mode might already exist (e.g., from a previous crash) -- try to continue
        // Check if the mode exists already by attempting addmode directly
    }

    // 4. Add the mode to the output
    rc = runCommandStatus("xrandr --addmode " + outputName_ + " \"" + modeName_ + "\"");
    if (rc != 0) {
        // Clean up the mode we just created
        runCommandStatus("xrandr --rmmode \"" + modeName_ + "\"");
        modeName_.clear();
        outputName_.clear();
        return false;
    }

    // 5. Enable the output with our mode
    rc = runCommandStatus("xrandr --output " + outputName_ +
                          " --mode \"" + modeName_ + "\" --right-of " +
                          runCommand("xrandr --query | grep ' connected primary' | awk '{print $1}'"));
    if (rc != 0) {
        // Try without --right-of (fallback: just enable it)
        rc = runCommandStatus("xrandr --output " + outputName_ +
                              " --mode \"" + modeName_ + "\"");
        if (rc != 0) {
            runCommandStatus("xrandr --delmode " + outputName_ + " \"" + modeName_ + "\"");
            runCommandStatus("xrandr --rmmode \"" + modeName_ + "\"");
            modeName_.clear();
            outputName_.clear();
            return false;
        }
    }

    return true;
}

std::string VirtualDisplayManager::findUnusedOutput() {
    std::string xrandrOut = runCommand("xrandr --query");
    if (xrandrOut.empty()) return {};

    // Preferred output names to look for (in priority order)
    static const std::vector<std::string> preferred = {
        "VIRTUAL", "DUMMY", "None"
    };

    std::istringstream stream(xrandrOut);
    std::string line;
    std::vector<std::string> disconnected;

    while (std::getline(stream, line)) {
        // Lines like: "VIRTUAL1 disconnected (normal left inverted ...)"
        //          or: "DP-2 disconnected (normal left inverted ...)"
        if (line.find(" disconnected") != std::string::npos) {
            auto spacePos = line.find(' ');
            if (spacePos != std::string::npos) {
                disconnected.push_back(line.substr(0, spacePos));
            }
        }
    }

    if (disconnected.empty()) return {};

    // Prefer outputs whose name starts with a preferred prefix
    for (const auto& prefix : preferred) {
        for (const auto& name : disconnected) {
            if (name.find(prefix) == 0) {
                return name;
            }
        }
    }

    // Fall back to the first disconnected output
    return disconnected.front();
}

std::string VirtualDisplayManager::computeModeline(int width, int height, int refreshRate) {
    std::ostringstream cmd;
    cmd << "cvt " << width << " " << height << " " << refreshRate;
    return runCommand(cmd.str());
}

int VirtualDisplayManager::resolveDisplayIndex(const std::string& outputName) const {
    // Parse xrandr --listmonitors to find the 0-based index
    // Output looks like:
    //   Monitors: 2
    //    0: +*eDP-1 1920/344x1080/194+0+0  eDP-1
    //    1: +VIRTUAL1 1920/438x1200/274+1920+0  VIRTUAL1
    std::string monitors = const_cast<VirtualDisplayManager*>(this)->runCommand(
        "xrandr --listmonitors");
    if (monitors.empty()) return 0;

    std::istringstream stream(monitors);
    std::string line;
    while (std::getline(stream, line)) {
        if (line.find(outputName) != std::string::npos) {
            // Find the leading index number
            auto colon = line.find(':');
            if (colon != std::string::npos) {
                std::string num;
                for (size_t i = 0; i < colon; ++i) {
                    if (std::isdigit(static_cast<unsigned char>(line[i]))) {
                        num += line[i];
                    }
                }
                if (!num.empty()) {
                    return std::stoi(num);
                }
            }
        }
    }

    return 0; // Fallback
}

// ---------------------------------------------------------------------------
// Backend 2: Xvfb (virtual framebuffer)
// ---------------------------------------------------------------------------

bool VirtualDisplayManager::tryXvfb(int width, int height, int refreshRate) {
    (void)refreshRate; // Xvfb doesn't support refresh rate config

    // Check if Xvfb is available
    if (runCommandStatus("which Xvfb") != 0) return false;

    // Find a free display number by trying :1, :2, ... :10
    int displayNum = -1;
    for (int i = 1; i <= 10; ++i) {
        std::string lockFile = "/tmp/.X" + std::to_string(i) + "-lock";
        if (access(lockFile.c_str(), F_OK) != 0) {
            displayNum = i;
            break;
        }
    }
    if (displayNum < 0) return false;

    xvfbDisplay_ = ":" + std::to_string(displayNum);
    std::ostringstream cmd;
    cmd << "Xvfb " << xvfbDisplay_
        << " -screen 0 " << width << "x" << height << "x24";

    // Fork to launch Xvfb in the background
    pid_t pid = fork();
    if (pid < 0) return false;

    if (pid == 0) {
        // Child: redirect stdout/stderr to /dev/null, exec Xvfb
        int devNull = open("/dev/null", O_WRONLY);
        if (devNull >= 0) {
            dup2(devNull, STDOUT_FILENO);
            dup2(devNull, STDERR_FILENO);
            close(devNull);
        }

        execlp("Xvfb", "Xvfb",
               xvfbDisplay_.c_str(),
               "-screen", "0",
               (std::to_string(width) + "x" + std::to_string(height) + "x24").c_str(),
               nullptr);

        // If exec fails
        _exit(127);
    }

    // Parent: give Xvfb a moment to start
    xvfbPid_ = pid;
    usleep(500'000); // 500ms

    // Verify it's still running
    int status = 0;
    pid_t ret = waitpid(xvfbPid_, &status, WNOHANG);
    if (ret != 0) {
        // Child already exited -- Xvfb failed to start
        xvfbPid_ = -1;
        xvfbDisplay_.clear();
        return false;
    }

    return true;
}

// ---------------------------------------------------------------------------
// Backend 3: PipeWire virtual monitor (stub -- requires PipeWire API)
// ---------------------------------------------------------------------------

bool VirtualDisplayManager::tryPipeWire(int width, int height, int refreshRate) {
    (void)width;
    (void)height;
    (void)refreshRate;

    // TODO: Implement PipeWire virtual monitor via org.freedesktop.portal.ScreenCast
    //       or the PipeWire C API. This requires creating a PipeWire stream
    //       configured as a virtual monitor sink.
    return false;
}

// ---------------------------------------------------------------------------
// Process execution helpers
// ---------------------------------------------------------------------------

std::string VirtualDisplayManager::runCommand(const std::string& cmd) {
    // Use fork/exec with a pipe to capture stdout
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
        close(pipeFd[0]); // close read end
        dup2(pipeFd[1], STDOUT_FILENO);
        dup2(pipeFd[1], STDERR_FILENO);
        close(pipeFd[1]);

        execl("/bin/sh", "sh", "-c", cmd.c_str(), nullptr);
        _exit(127);
    }

    // Parent
    close(pipeFd[1]); // close write end

    // Read all output
    std::string output;
    char buf[4096];
    ssize_t n;
    while ((n = read(pipeFd[0], buf, sizeof(buf))) > 0) {
        output.append(buf, static_cast<size_t>(n));
    }
    close(pipeFd[0]);

    // Wait with timeout
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

int VirtualDisplayManager::runCommandStatus(const std::string& cmd) {
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

    // Timeout
    kill(pid, SIGKILL);
    waitpid(pid, &status, 0);
    return -1;
}
