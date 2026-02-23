#include "capture/ScreenCapture.h"

#ifdef HAS_PIPEWIRE
#include "capture/PipeWireCapture.h"
#endif

#ifdef HAS_X11
#include "capture/X11Capture.h"
#endif

#include <cstdlib>
#include <cstring>
#include <iostream>

/**
 * Auto-detect the best screen capture backend.
 *
 * Priority order:
 *   1. PipeWire  — preferred on modern Wayland desktops
 *   2. X11       — fallback for X11 sessions or older systems
 *
 * Detection heuristic:
 *   - If $WAYLAND_DISPLAY is set and PipeWire was compiled in, use PipeWire.
 *   - If $DISPLAY is set and X11 was compiled in, use X11.
 *   - Otherwise return nullptr.
 */
std::unique_ptr<ScreenCapture> ScreenCapture::create() {
    // ------------------------------------------------------------------
    // 1. Try PipeWire on Wayland
    // ------------------------------------------------------------------
#ifdef HAS_PIPEWIRE
    {
        const char* waylandDisplay = std::getenv("WAYLAND_DISPLAY");
        if (waylandDisplay && std::strlen(waylandDisplay) > 0) {
            std::cout << "[ScreenCapture] Wayland session detected, using PipeWire capture\n";
            return std::make_unique<PipeWireCapture>();
        }
    }
#endif

    // ------------------------------------------------------------------
    // 2. Try X11
    // ------------------------------------------------------------------
#ifdef HAS_X11
    {
        const char* x11Display = std::getenv("DISPLAY");
        if (x11Display && std::strlen(x11Display) > 0) {
            std::cout << "[ScreenCapture] X11 session detected, using X11 capture\n";
            return std::make_unique<X11Capture>();
        }
    }
#endif

    // ------------------------------------------------------------------
    // 3. Also try PipeWire even without WAYLAND_DISPLAY
    //    (some hybrid setups run PipeWire on X11)
    // ------------------------------------------------------------------
#ifdef HAS_PIPEWIRE
    {
        std::cout << "[ScreenCapture] No Wayland display, but PipeWire is available — "
                     "attempting PipeWire capture\n";
        return std::make_unique<PipeWireCapture>();
    }
#endif

    std::cerr << "[ScreenCapture] ERROR: No capture backend available. "
                 "Compile with HAS_PIPEWIRE or HAS_X11.\n";
    return nullptr;
}
