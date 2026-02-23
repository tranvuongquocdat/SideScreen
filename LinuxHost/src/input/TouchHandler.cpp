#include "TouchHandler.h"
#include <cmath>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>

// uinput headers (available on all Linux systems)
#include <fcntl.h>
#include <unistd.h>
#include <linux/uinput.h>
#include <linux/input.h>
#include <sys/ioctl.h>

// ---------------------------------------------------------------------------
// Construction / Destruction
// ---------------------------------------------------------------------------

TouchHandler::TouchHandler() {
    touchStartTime_    = std::chrono::steady_clock::now();
    touchLastMoveTime_ = touchStartTime_;
    lastTapTime_       = std::chrono::steady_clock::time_point{};  // epoch

#ifdef HAS_XDO
    xdo_ = xdo_new(nullptr);  // Uses $DISPLAY or $WAYLAND_DISPLAY
    if (xdo_) {
        std::fprintf(stderr, "[TouchHandler] libxdo backend initialised\n");
    } else {
        std::fprintf(stderr, "[TouchHandler] libxdo init failed, falling back to xdotool CLI\n");
    }
#else
    std::fprintf(stderr, "[TouchHandler] Compiled without libxdo, using xdotool CLI fallback\n");
#endif

    initUinput();
}

TouchHandler::~TouchHandler() {
    stopMomentumScroll();
    cancelLongPressTimer();

#ifdef HAS_XDO
    if (xdo_) {
        xdo_free(xdo_);
        xdo_ = nullptr;
    }
#endif

    cleanupUinput();
}

// ---------------------------------------------------------------------------
// uinput initialisation for smooth scroll events
// ---------------------------------------------------------------------------

void TouchHandler::initUinput() {
    uinputFd_ = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (uinputFd_ < 0) {
        std::fprintf(stderr, "[TouchHandler] Cannot open /dev/uinput: %s. "
                     "Smooth scroll via uinput disabled.\n", std::strerror(errno));
        return;
    }

    // Enable EV_REL events (for REL_WHEEL / REL_HWHEEL)
    if (ioctl(uinputFd_, UI_SET_EVBIT, EV_REL) < 0 ||
        ioctl(uinputFd_, UI_SET_RELBIT, REL_WHEEL) < 0 ||
        ioctl(uinputFd_, UI_SET_RELBIT, REL_HWHEEL) < 0) {
        std::fprintf(stderr, "[TouchHandler] ioctl uinput setup failed\n");
        close(uinputFd_);
        uinputFd_ = -1;
        return;
    }

    // Enable EV_KEY for BTN_LEFT (required by some compositors to accept the device)
    ioctl(uinputFd_, UI_SET_EVBIT, EV_KEY);
    ioctl(uinputFd_, UI_SET_KEYBIT, BTN_LEFT);

    // Enable EV_SYN
    ioctl(uinputFd_, UI_SET_EVBIT, EV_SYN);

    struct uinput_setup usetup{};
    std::strncpy(usetup.name, "SideScreen Virtual Scroll", UINPUT_MAX_NAME_SIZE - 1);
    usetup.id.bustype = BUS_VIRTUAL;
    usetup.id.vendor  = 0x1234;
    usetup.id.product = 0x5678;

    if (ioctl(uinputFd_, UI_DEV_SETUP, &usetup) < 0 ||
        ioctl(uinputFd_, UI_DEV_CREATE) < 0) {
        std::fprintf(stderr, "[TouchHandler] uinput device creation failed\n");
        close(uinputFd_);
        uinputFd_ = -1;
        return;
    }

    std::fprintf(stderr, "[TouchHandler] uinput scroll device created\n");
}

void TouchHandler::cleanupUinput() {
    if (uinputFd_ >= 0) {
        ioctl(uinputFd_, UI_DEV_DESTROY);
        close(uinputFd_);
        uinputFd_ = -1;
    }
}

void TouchHandler::uinputScroll(int deltaX, int deltaY) {
    if (uinputFd_ < 0) return;

    auto emitEvent = [this](uint16_t type, uint16_t code, int32_t value) {
        struct input_event ev{};
        ev.type  = type;
        ev.code  = code;
        ev.value = value;
        ::write(uinputFd_, &ev, sizeof(ev));
    };

    if (deltaY != 0) {
        // REL_WHEEL: positive = scroll up, negative = scroll down.
        // Our deltaY is positive for "scroll content down" (finger moves down),
        // which means scroll wheel UP on X11.
        emitEvent(EV_REL, REL_WHEEL, deltaY);
    }
    if (deltaX != 0) {
        emitEvent(EV_REL, REL_HWHEEL, deltaX);
    }

    // SYN_REPORT to flush
    emitEvent(EV_SYN, SYN_REPORT, 0);
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

void TouchHandler::setDisplayBounds(int x, int y, int width, int height) {
    std::lock_guard<std::mutex> lock(mutex_);
    displayX_      = x;
    displayY_      = y;
    displayWidth_  = width;
    displayHeight_ = height;
}

void TouchHandler::handleTouch(int pointerCount, float x1, float y1,
                               float x2, float y2, int action) {
    // Convert normalised coordinates to screen pixels.
    auto [sx1, sy1] = normalizedToScreen(x1, y1);

    if (pointerCount >= 2) {
        auto [sx2, sy2] = normalizedToScreen(x2, y2);
        handleTwoFingerTouch(sx1, sy1, sx2, sy2, action);
    } else {
        handleOneFingerTouch(sx1, sy1, action);
    }
}

std::pair<int, int> TouchHandler::normalizedToScreen(float nx, float ny) const {
    std::lock_guard<std::mutex> lock(mutex_);
    // X11 uses absolute screen pixels -- no 0-65535 mapping needed.
    int sx = displayX_ + static_cast<int>(nx * displayWidth_);
    int sy = displayY_ + static_cast<int>(ny * displayHeight_);
    return {sx, sy};
}

// ---------------------------------------------------------------------------
// Coordinate Helpers
// ---------------------------------------------------------------------------

float TouchHandler::distance(int x1, int y1, int x2, int y2) {
    float dx = static_cast<float>(x2 - x1);
    float dy = static_cast<float>(y2 - y1);
    return std::sqrt(dx * dx + dy * dy);
}

// ---------------------------------------------------------------------------
// 1-Finger Gesture State Machine
// ---------------------------------------------------------------------------

void TouchHandler::handleOneFingerTouch(int sx, int sy, int action) {
    switch (action) {
    case 0: oneFingerDown(sx, sy); break;
    case 1: oneFingerMove(sx, sy); break;
    case 2: oneFingerUp(sx, sy);   break;
    default: break;
    }
}

void TouchHandler::oneFingerDown(int x, int y) {
    // Stop any ongoing momentum/long-press BEFORE taking the lock,
    // since stopMomentumScroll joins a thread that also locks mutex_.
    stopMomentumScroll();
    cancelLongPressTimer();

    {
        std::lock_guard<std::mutex> lock(mutex_);
        touchStartX_       = x;
        touchStartY_       = y;
        touchLastX_        = x;
        touchLastY_        = y;
        touchStartTime_    = std::chrono::steady_clock::now();
        touchLastMoveTime_ = touchStartTime_;
        state_ = GestureState::Pending;
    }

    // Move cursor to touch position.
    injectMouseMove(x, y);

    // Start long-press detection.
    startLongPressTimer();
}

void TouchHandler::oneFingerMove(int x, int y) {
    // Snapshot state under lock, decide action, then inject outside lock.
    enum class Action { None, StartScroll, Scroll, StartDrag, Drag };
    Action todo = Action::None;

    float sx = 0, sy = 0;
    int dragStartX = 0, dragStartY = 0;

    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto now = std::chrono::steady_clock::now();

        float deltaX   = static_cast<float>(x - touchLastX_);
        float deltaY   = static_cast<float>(y - touchLastY_);
        float totalDist = distance(touchStartX_, touchStartY_, x, y);

        switch (state_) {
        case GestureState::Pending:
            if (totalDist > Config::TAP_MAX_DISTANCE) {
                state_ = GestureState::Scrolling;
                sx = deltaX * Config::SCROLL_SENSITIVITY;
                sy = deltaY * Config::SCROLL_SENSITIVITY;
                lastScrollDeltaX_ = sx;
                lastScrollDeltaY_ = sy;
                todo = Action::StartScroll;
            }
            break;

        case GestureState::LongPressReady:
            if (totalDist > Config::TAP_MAX_DISTANCE) {
                state_ = GestureState::Dragging;
                dragStartX = touchStartX_;
                dragStartY = touchStartY_;
                todo = Action::StartDrag;
            }
            break;

        case GestureState::Scrolling: {
            sx = deltaX * Config::SCROLL_SENSITIVITY;
            sy = deltaY * Config::SCROLL_SENSITIVITY;
            auto timeDelta = std::chrono::duration_cast<std::chrono::milliseconds>(
                now - touchLastMoveTime_).count();
            if (timeDelta > 0 && timeDelta < 100) {
                lastScrollDeltaX_ = sx;
                lastScrollDeltaY_ = sy;
            }
            todo = Action::Scroll;
            break;
        }

        case GestureState::Dragging:
            todo = Action::Drag;
            break;

        default:
            break;
        }

        touchLastX_        = x;
        touchLastY_        = y;
        touchLastMoveTime_ = now;
    }

    // Perform actions outside the lock.
    switch (todo) {
    case Action::StartScroll:
        cancelLongPressTimer();
        injectScroll(x, y, static_cast<int>(sx), static_cast<int>(sy));
        break;
    case Action::Scroll:
        injectScroll(x, y, static_cast<int>(sx), static_cast<int>(sy));
        break;
    case Action::StartDrag:
        injectMouseDown(dragStartX, dragStartY);
        injectMouseMove(x, y);
        break;
    case Action::Drag:
        injectMouseMove(x, y);
        break;
    case Action::None:
    default:
        break;
    }
}

void TouchHandler::oneFingerUp(int x, int y) {
    cancelLongPressTimer();

    // Snapshot state under lock, decide action.
    enum class Action { None, SingleTap, DoubleTap, RightClick, MomentumScroll, DragEnd };
    Action todo = Action::None;
    float vx = 0, vy = 0;

    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto now     = std::chrono::steady_clock::now();
        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            now - touchStartTime_).count();
        float dist   = distance(touchStartX_, touchStartY_, x, y);

        switch (state_) {
        case GestureState::Pending: {
            if (dist < Config::TAP_MAX_DISTANCE && elapsed < Config::TAP_MAX_TIME_MS) {
                auto timeSinceLastTap = std::chrono::duration_cast<std::chrono::milliseconds>(
                    now - lastTapTime_).count();
                float distFromLastTap = distance(lastTapX_, lastTapY_, x, y);

                if (hasLastTap_
                    && timeSinceLastTap < Config::DOUBLE_TAP_MAX_TIME_MS
                    && distFromLastTap < Config::DOUBLE_TAP_MAX_DISTANCE) {
                    todo = Action::DoubleTap;
                    hasLastTap_ = false;  // Reset to prevent triple-tap.
                } else {
                    todo = Action::SingleTap;
                    lastTapTime_ = now;
                    lastTapX_    = x;
                    lastTapY_    = y;
                    hasLastTap_  = true;
                }
            }
            break;
        }

        case GestureState::LongPressReady:
            todo = Action::RightClick;
            break;

        case GestureState::Scrolling: {
            auto timeSinceLastMove = std::chrono::duration_cast<std::chrono::milliseconds>(
                now - touchLastMoveTime_).count();
            if (timeSinceLastMove < 50) {
                float threshold = 2.0f;
                if (std::abs(lastScrollDeltaX_) > threshold ||
                    std::abs(lastScrollDeltaY_) > threshold) {
                    vx = lastScrollDeltaX_ * 6.0f;
                    vy = lastScrollDeltaY_ * 6.0f;
                    todo = Action::MomentumScroll;
                }
            }
            break;
        }

        case GestureState::Dragging:
            todo = Action::DragEnd;
            break;

        default:
            break;
        }

        state_ = GestureState::Idle;
    }

    // Perform actions outside the lock.
    switch (todo) {
    case Action::SingleTap:
        injectMouseDown(x, y);
        injectMouseUp(x, y);
        break;
    case Action::DoubleTap:
        injectDoubleClick(x, y);
        break;
    case Action::RightClick:
        injectRightDown(x, y);
        injectRightUp(x, y);
        break;
    case Action::MomentumScroll:
        {
            std::lock_guard<std::mutex> lock(mutex_);
            momentumX_ = x;
            momentumY_ = y;
        }
        startMomentumScroll(vx, vy);
        break;
    case Action::DragEnd:
        injectMouseUp(x, y);
        break;
    case Action::None:
    default:
        break;
    }
}

// ---------------------------------------------------------------------------
// 2-Finger Gesture Logic
// ---------------------------------------------------------------------------

void TouchHandler::handleTwoFingerTouch(int x1, int y1, int x2, int y2, int action) {
    float dist = distance(x1, y1, x2, y2);
    int midX = (x1 + x2) / 2;
    int midY = (y1 + y2) / 2;

    switch (action) {
    case 0: { // Down
        cancelLongPressTimer();
        stopMomentumScroll();
        std::lock_guard<std::mutex> lock(mutex_);
        state_ = GestureState::Idle;  // Reset for fresh 2-finger detection.
        initialPinchDistance_ = dist;
        lastPinchDistance_    = dist;
        twoFingerLastMidX_   = midX;
        twoFingerLastMidY_   = midY;
        break;
    }

    case 1: { // Move
        enum class Action2 { None, Scroll2F, Pinch };
        Action2 todo = Action2::None;
        float dx = 0, dy = 0;
        int zoomAmount = 0;

        {
            std::lock_guard<std::mutex> lock(mutex_);
            float distChange = std::abs(dist - initialPinchDistance_);
            float midDelta   = distance(twoFingerLastMidX_, twoFingerLastMidY_, midX, midY);

            // Determine mode if not yet decided.
            if (state_ != GestureState::TwoFingerScroll && state_ != GestureState::Pinching) {
                if (distChange > Config::PINCH_MIN_DISTANCE) {
                    state_ = GestureState::Pinching;
                } else if (midDelta > Config::TAP_MAX_DISTANCE) {
                    state_ = GestureState::TwoFingerScroll;
                }
            }

            switch (state_) {
            case GestureState::TwoFingerScroll:
                dx = static_cast<float>(midX - twoFingerLastMidX_) * Config::SCROLL_SENSITIVITY;
                dy = static_cast<float>(midY - twoFingerLastMidY_) * Config::SCROLL_SENSITIVITY;
                todo = Action2::Scroll2F;
                break;
            case GestureState::Pinching: {
                float scaleDelta = dist - lastPinchDistance_;
                zoomAmount = static_cast<int>(scaleDelta * 0.5f);
                lastPinchDistance_ = dist;
                if (zoomAmount != 0) {
                    todo = Action2::Pinch;
                }
                break;
            }
            default:
                break;
            }

            twoFingerLastMidX_ = midX;
            twoFingerLastMidY_ = midY;
        }

        // Inject outside lock.
        switch (todo) {
        case Action2::Scroll2F:
            injectScroll(midX, midY, static_cast<int>(dx), static_cast<int>(dy));
            break;
        case Action2::Pinch:
            injectZoom(midX, midY, zoomAmount);
            break;
        case Action2::None:
        default:
            break;
        }
        break;
    }

    case 2: { // Up
        std::lock_guard<std::mutex> lock(mutex_);
        state_ = GestureState::Idle;
        // Reset 1-finger tracking to avoid stale deltas.
        touchStartX_ = 0;
        touchStartY_ = 0;
        touchLastX_  = 0;
        touchLastY_  = 0;
        break;
    }

    default:
        break;
    }
}

// ---------------------------------------------------------------------------
// Linux Input Injection
// ---------------------------------------------------------------------------
//
// Backend priority:
//   1. libxdo (if compiled with HAS_XDO and xdo_new succeeded)
//   2. xdotool CLI fallback (system() calls)
//
// X11 uses absolute screen-pixel coordinates directly (no 0-65535 mapping).
// ---------------------------------------------------------------------------

void TouchHandler::injectMouseMove(int x, int y) {
#ifdef HAS_XDO
    if (xdo_) {
        xdo_move_mouse(xdo_, x, y, 0);
        return;
    }
#endif
    // xdotool CLI fallback
    char cmd[128];
    std::snprintf(cmd, sizeof(cmd), "xdotool mousemove %d %d", x, y);
    std::system(cmd);
}

void TouchHandler::injectMouseDown(int x, int y) {
    injectMouseMove(x, y);
#ifdef HAS_XDO
    if (xdo_) {
        xdo_mouse_down(xdo_, CURRENTWINDOW, 1);  // button 1 = left
        return;
    }
#endif
    std::system("xdotool mousedown 1");
}

void TouchHandler::injectMouseUp(int x, int y) {
    injectMouseMove(x, y);
#ifdef HAS_XDO
    if (xdo_) {
        xdo_mouse_up(xdo_, CURRENTWINDOW, 1);
        return;
    }
#endif
    std::system("xdotool mouseup 1");
}

void TouchHandler::injectRightDown(int x, int y) {
    injectMouseMove(x, y);
#ifdef HAS_XDO
    if (xdo_) {
        xdo_mouse_down(xdo_, CURRENTWINDOW, 3);  // button 3 = right
        return;
    }
#endif
    std::system("xdotool mousedown 3");
}

void TouchHandler::injectRightUp(int x, int y) {
    injectMouseMove(x, y);
#ifdef HAS_XDO
    if (xdo_) {
        xdo_mouse_up(xdo_, CURRENTWINDOW, 3);
        return;
    }
#endif
    std::system("xdotool mouseup 3");
}

void TouchHandler::injectScroll(int x, int y, int deltaX, int deltaY) {
    // Move cursor to the scroll position first so the scroll event targets
    // the correct window.
    injectMouseMove(x, y);

    // Try uinput first for smooth pixel-level scrolling.
    if (uinputFd_ >= 0) {
        // Scale pixel deltas to scroll "notches".  X11 scroll buttons are
        // discrete, but uinput REL_WHEEL can produce fractional-feeling
        // scroll at high event rates.  We map ~10 pixels = 1 scroll unit.
        int scrollY = deltaY / 10;
        int scrollX = deltaX / 10;
        if (scrollY != 0 || scrollX != 0) {
            uinputScroll(scrollX, scrollY);
        }
        return;
    }

    // Fallback: X11 scroll buttons (4=up, 5=down, 6=left, 7=right).
    // Each click is one "notch", so we repeat for larger deltas.
    auto clickButton = [this](int button, int count) {
        for (int i = 0; i < count; ++i) {
#ifdef HAS_XDO
            if (xdo_) {
                xdo_click_window(xdo_, CURRENTWINDOW, button);
                continue;
            }
#endif
            char cmd[64];
            std::snprintf(cmd, sizeof(cmd), "xdotool click %d", button);
            std::system(cmd);
        }
    };

    // Vertical scroll: button 4 = scroll up, button 5 = scroll down.
    // Our deltaY positive = finger moved down = scroll content down = wheel UP.
    if (deltaY > 0) {
        int notches = std::max(1, std::abs(deltaY) / 10);
        clickButton(4, notches);  // scroll up
    } else if (deltaY < 0) {
        int notches = std::max(1, std::abs(deltaY) / 10);
        clickButton(5, notches);  // scroll down
    }

    // Horizontal scroll: button 6 = scroll left, button 7 = scroll right.
    if (deltaX > 0) {
        int notches = std::max(1, std::abs(deltaX) / 10);
        clickButton(7, notches);  // scroll right
    } else if (deltaX < 0) {
        int notches = std::max(1, std::abs(deltaX) / 10);
        clickButton(6, notches);  // scroll left
    }
}

void TouchHandler::injectDoubleClick(int x, int y) {
    // Two rapid left-click pairs at the same position.
    injectMouseDown(x, y);
    injectMouseUp(x, y);
    injectMouseDown(x, y);
    injectMouseUp(x, y);
}

void TouchHandler::injectZoom(int x, int y, int delta) {
    // Pinch zoom on Linux: hold Ctrl then scroll (same as Windows).
    injectMouseMove(x, y);

#ifdef HAS_XDO
    if (xdo_) {
        // Press Ctrl
        xdo_send_keysequence_window_down(xdo_, CURRENTWINDOW, "Control_L", 0);

        // Scroll: positive delta = zoom in (scroll up = button 4),
        //         negative delta = zoom out (scroll down = button 5).
        int button = (delta > 0) ? 4 : 5;
        int clicks = std::max(1, std::abs(delta));
        for (int i = 0; i < clicks; ++i) {
            xdo_click_window(xdo_, CURRENTWINDOW, button);
        }

        // Release Ctrl
        xdo_send_keysequence_window_up(xdo_, CURRENTWINDOW, "Control_L", 0);
        return;
    }
#endif

    // xdotool CLI fallback: Ctrl + scroll
    std::system("xdotool keydown Control_L");

    int button = (delta > 0) ? 4 : 5;
    int clicks = std::max(1, std::abs(delta));
    for (int i = 0; i < clicks; ++i) {
        char cmd[64];
        std::snprintf(cmd, sizeof(cmd), "xdotool click %d", button);
        std::system(cmd);
    }

    std::system("xdotool keyup Control_L");
}

// ---------------------------------------------------------------------------
// Long-Press Timer
// ---------------------------------------------------------------------------

void TouchHandler::startLongPressTimer() {
    cancelLongPressTimer();  // Ensure no stale timer is running.

    longPressActive_.store(true);
    longPressFired_.store(false);

    longPressThread_ = std::thread([this]() {
        auto start = std::chrono::steady_clock::now();
        while (longPressActive_.load()) {
            auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - start).count();
            if (elapsed >= Config::LONG_PRESS_TIME_MS) {
                // Time's up -- transition if still in Pending state.
                std::lock_guard<std::mutex> lock(mutex_);
                if (state_ == GestureState::Pending) {
                    state_ = GestureState::LongPressReady;
                    longPressFired_.store(true);
                }
                return;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
    });
}

void TouchHandler::cancelLongPressTimer() {
    longPressActive_.store(false);
    if (longPressThread_.joinable()) {
        longPressThread_.join();
    }
}

// ---------------------------------------------------------------------------
// Momentum Scrolling
// ---------------------------------------------------------------------------

void TouchHandler::startMomentumScroll(float velocityX, float velocityY) {
    stopMomentumScroll();

    {
        std::lock_guard<std::mutex> lock(mutex_);
        momentumVelocityX_ = velocityX;
        momentumVelocityY_ = velocityY;
    }
    momentumRunning_.store(true);

    momentumThread_ = std::thread(&TouchHandler::momentumThreadFunc, this);
}

void TouchHandler::stopMomentumScroll() {
    momentumRunning_.store(false);
    if (momentumThread_.joinable()) {
        momentumThread_.join();
    }
    std::lock_guard<std::mutex> lock(mutex_);
    momentumVelocityX_ = 0.0f;
    momentumVelocityY_ = 0.0f;
}

void TouchHandler::momentumThreadFunc() {
    while (momentumRunning_.load()) {
        int mx, my;
        float vx, vy;

        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (std::abs(momentumVelocityX_) < Config::MOMENTUM_MIN_VELOCITY &&
                std::abs(momentumVelocityY_) < Config::MOMENTUM_MIN_VELOCITY) {
                momentumRunning_.store(false);
                break;
            }
            mx = momentumX_;
            my = momentumY_;
            vx = momentumVelocityX_;
            vy = momentumVelocityY_;
        }

        injectScroll(mx, my, static_cast<int>(vx), static_cast<int>(vy));

        {
            std::lock_guard<std::mutex> lock(mutex_);
            momentumVelocityX_ *= Config::MOMENTUM_DECAY;  // 0.92 decay
            momentumVelocityY_ *= Config::MOMENTUM_DECAY;
        }

        std::this_thread::sleep_for(
            std::chrono::milliseconds(Config::MOMENTUM_INTERVAL_MS));  // ~60Hz
    }
}
