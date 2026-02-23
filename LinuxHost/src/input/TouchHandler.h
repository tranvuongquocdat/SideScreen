#pragma once

#include <cstdint>
#include <utility>
#include <mutex>
#include <atomic>
#include <thread>
#include <chrono>
#include <string>

#ifdef HAS_XDO
extern "C" {
#include <xdo.h>
}
#endif

#include "../Config.h"

/// Gesture states mirroring the macOS/Windows host state machine exactly.
enum class GestureState {
    Idle,
    Pending,          // Touch down, waiting to determine gesture type
    Scrolling,        // 1-finger scroll (finger moved beyond tap threshold)
    LongPressReady,   // Held past LONG_PRESS_TIME_MS without moving
    Dragging,         // Long press + drag (left mouse drag)
    TwoFingerScroll,  // 2-finger pan
    Pinching          // 2-finger pinch zoom
};

/// Converts normalized touch coordinates from the Android client into Linux
/// input events using the same gesture state machine as the macOS/Windows hosts.
///
/// Input injection backends (tried in order):
///   1. libxdo (if HAS_XDO is defined at compile time)
///   2. xdotool CLI fallback (system() calls)
///   3. uinput for smooth scroll/REL_WHEEL events
///
/// Thread safety: handleTouch() is called from the network receive thread.
/// Momentum scrolling runs on its own background thread.  All shared state is
/// protected by mutex_.
class TouchHandler {
public:
    TouchHandler();
    ~TouchHandler();

    // Non-copyable, non-movable
    TouchHandler(const TouchHandler&) = delete;
    TouchHandler& operator=(const TouchHandler&) = delete;

    /// Set the virtual display region that touch coordinates map to.
    /// @param x       Left edge of display in screen pixels.
    /// @param y       Top edge of display in screen pixels.
    /// @param width   Width of display in pixels.
    /// @param height  Height of display in pixels.
    void setDisplayBounds(int x, int y, int width, int height);

    /// Main entry point -- called from the network receive thread.
    /// @param pointerCount  1 or 2 fingers.
    /// @param x1,y1         First pointer, normalised [0..1].
    /// @param x2,y2         Second pointer, normalised [0..1] (only when pointerCount >= 2).
    /// @param action        0 = down, 1 = move, 2 = up.
    void handleTouch(int pointerCount, float x1, float y1,
                     float x2, float y2, int action);

    /// Convert normalised [0..1] coordinates to screen pixels within the
    /// configured display bounds.
    std::pair<int, int> normalizedToScreen(float nx, float ny) const;

private:
    // -- Coordinate helpers ---------------------------------------------------
    static float distance(int x1, int y1, int x2, int y2);

    // -- 1-finger gesture logic -----------------------------------------------
    void handleOneFingerTouch(int sx, int sy, int action);
    void oneFingerDown(int x, int y);
    void oneFingerMove(int x, int y);
    void oneFingerUp(int x, int y);

    // -- 2-finger gesture logic -----------------------------------------------
    void handleTwoFingerTouch(int x1, int y1, int x2, int y2, int action);

    // -- Linux input injection ------------------------------------------------
    void injectMouseMove(int x, int y);
    void injectMouseDown(int x, int y);
    void injectMouseUp(int x, int y);
    void injectRightDown(int x, int y);
    void injectRightUp(int x, int y);
    void injectScroll(int x, int y, int deltaX, int deltaY);
    void injectDoubleClick(int x, int y);

    // -- Long-press timer -----------------------------------------------------
    void startLongPressTimer();
    void cancelLongPressTimer();

    // -- Momentum scrolling ---------------------------------------------------
    void startMomentumScroll(float velocityX, float velocityY);
    void stopMomentumScroll();
    void momentumThreadFunc();

    // -- Pinch zoom (Ctrl + scroll) -------------------------------------------
    void injectZoom(int x, int y, int delta);

    // -- uinput for smooth scroll ---------------------------------------------
    void initUinput();
    void cleanupUinput();
    void uinputScroll(int deltaX, int deltaY);

    // -- Shared state (protected by mutex_) -----------------------------------
    mutable std::mutex mutex_;

    // Display bounds
    int displayX_      = 0;
    int displayY_      = 0;
    int displayWidth_   = Config::DEFAULT_WIDTH;
    int displayHeight_  = Config::DEFAULT_HEIGHT;

    // State machine
    GestureState state_ = GestureState::Idle;

    // 1-finger tracking
    int touchStartX_    = 0;
    int touchStartY_    = 0;
    int touchLastX_     = 0;
    int touchLastY_     = 0;
    std::chrono::steady_clock::time_point touchStartTime_;
    std::chrono::steady_clock::time_point touchLastMoveTime_;
    float lastScrollDeltaX_ = 0.0f;
    float lastScrollDeltaY_ = 0.0f;

    // Double-tap tracking
    std::chrono::steady_clock::time_point lastTapTime_;
    int lastTapX_       = 0;
    int lastTapY_       = 0;
    bool hasLastTap_    = false;

    // Long-press timer
    std::thread longPressThread_;
    std::atomic<bool> longPressActive_{false};
    std::atomic<bool> longPressFired_{false};

    // 2-finger tracking
    float initialPinchDistance_ = 0.0f;
    float lastPinchDistance_    = 0.0f;
    int twoFingerLastMidX_     = 0;
    int twoFingerLastMidY_     = 0;

    // Momentum scrolling
    std::thread momentumThread_;
    std::atomic<bool> momentumRunning_{false};
    float momentumVelocityX_ = 0.0f;
    float momentumVelocityY_ = 0.0f;
    int   momentumX_         = 0;
    int   momentumY_         = 0;

    // libxdo handle (null if unavailable)
#ifdef HAS_XDO
    xdo_t* xdo_ = nullptr;
#endif

    // uinput file descriptor (-1 if unavailable)
    int uinputFd_ = -1;
};
