#pragma once

#include <string>
#include <vector>
#include <cstdint>

/**
 * VirtualDisplayManager -- create and manage a virtual monitor on Linux.
 *
 * Approach (tried in order):
 *   1. xrandr dummy output  -- find an unused/disconnected output and add a
 *      virtual mode to it (works on X11 with VIRTUAL1, HDMI-*, DP-*, etc.)
 *   2. Xvfb / Xdummy        -- create a virtual framebuffer as a new X display
 *   3. PipeWire virtual monitor (Wayland) -- if HAS_PIPEWIRE
 *
 * Position persistence:
 *   Saved to ~/.config/sidescreen/display_position  (key=value format).
 */
class VirtualDisplayManager {
public:
    VirtualDisplayManager();
    ~VirtualDisplayManager();

    // Non-copyable
    VirtualDisplayManager(const VirtualDisplayManager&) = delete;
    VirtualDisplayManager& operator=(const VirtualDisplayManager&) = delete;

    /**
     * Create a virtual display with the given resolution and refresh rate.
     * Tries xrandr dummy output first, then Xvfb, then PipeWire.
     * @return true on success
     */
    bool createDisplay(int width, int height, int refreshRate);

    /**
     * Destroy the virtual display and clean up any resources.
     * Safe to call multiple times.
     */
    void destroyDisplay();

    /** @return true if a virtual display is currently active. */
    bool isDisplayCreated() const;

    /** Human-readable name, e.g. "VIRTUAL1" or ":1". */
    std::string displayName() const;

    /**
     * 0-based display/monitor index suitable for ScreenCapture::initialize().
     * Returns -1 if no display is created.
     */
    int displayIndex() const;

    /** Save the current xrandr position to the config file. */
    void savePosition();

    /** Restore the previously saved position (xrandr --output ... --pos XxY). */
    void restorePosition();

private:
    // ----- backend helpers (tried in order) ----------------------------------
    bool tryXrandrDummy(int width, int height, int refreshRate);
    bool tryXvfb(int width, int height, int refreshRate);
    bool tryPipeWire(int width, int height, int refreshRate);

    // ----- xrandr helpers ----------------------------------------------------
    /** Find a disconnected or virtual output name via xrandr --query. */
    std::string findUnusedOutput();

    /** Use cvt to compute a modeline string for the given resolution/refresh. */
    std::string computeModeline(int width, int height, int refreshRate);

    /** Parse the output-index from xrandr --listmonitors. */
    int resolveDisplayIndex(const std::string& outputName);

    // ----- position persistence ----------------------------------------------
    std::string configDir() const;
    std::string positionFilePath() const;

    // ----- process helpers ---------------------------------------------------

    /**
     * Run a shell command, capture stdout.
     * Uses fork/exec + pipe (no system()).
     * Returns empty string on failure.
     */
    std::string runCommand(const std::string& cmd);

    /**
     * Run a shell command and return exit status.
     * Uses fork/exec with 5-second timeout.
     * Returns -1 on error/timeout.
     */
    int runCommandStatus(const std::string& cmd);

    // ----- state -------------------------------------------------------------
    enum class Backend {
        None,
        Xrandr,
        Xvfb,
        PipeWire
    };

    Backend backend_ = Backend::None;
    bool created_ = false;

    // xrandr state
    std::string modeName_;   // e.g. "1920x1200_120.00"
    std::string outputName_; // e.g. "VIRTUAL1"

    // Xvfb state
    pid_t xvfbPid_ = -1;
    std::string xvfbDisplay_; // e.g. ":1"

    // Dimensions (for reference)
    int width_ = 0;
    int height_ = 0;
    int refreshRate_ = 0;
};
