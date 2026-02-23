#include "TouchHandler.h"
#include <cmath>
#include <algorithm>

// ---------------------------------------------------------------------------
// Construction / Destruction
// ---------------------------------------------------------------------------

TouchHandler::TouchHandler() {
    touchStartTime_    = std::chrono::steady_clock::now();
    touchLastMoveTime_ = touchStartTime_;
    lastTapTime_       = std::chrono::steady_clock::time_point{};  // epoch
}

TouchHandler::~TouchHandler() {
    stopMomentumScroll();
    cancelLongPressTimer();
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
    int sx = displayX_ + static_cast<int>(nx * displayWidth_);
    int sy = displayY_ + static_cast<int>(ny * displayHeight_);
    return {sx, sy};
}

// ---------------------------------------------------------------------------
// Coordinate Helpers
// ---------------------------------------------------------------------------

std::pair<LONG, LONG> TouchHandler::screenToAbsolute(int sx, int sy) const {
    // SendInput with MOUSEEVENTF_ABSOLUTE uses coordinates in the range
    // [0, 65535] mapped over the entire virtual screen.
    int vsX = GetSystemMetrics(SM_XVIRTUALSCREEN);
    int vsY = GetSystemMetrics(SM_YVIRTUALSCREEN);
    int vsW = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    int vsH = GetSystemMetrics(SM_CYVIRTUALSCREEN);

    if (vsW <= 0) vsW = 1;
    if (vsH <= 0) vsH = 1;

    LONG ax = static_cast<LONG>(((sx - vsX) * 65535) / vsW);
    LONG ay = static_cast<LONG>(((sy - vsY) * 65535) / vsH);

    ax = std::clamp(ax, 0L, 65535L);
    ay = std::clamp(ay, 0L, 65535L);
    return {ax, ay};
}

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

    // Move cursor to touch position (no lock needed for SendInput).
    injectMouseMove(x, y);

    // Start long-press detection (spawns a detached thread that will lock
    // mutex_ when it fires).
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
// Windows Input Injection via SendInput
// ---------------------------------------------------------------------------

void TouchHandler::injectMouseMove(int x, int y) {
    auto [ax, ay] = screenToAbsolute(x, y);

    INPUT inp{};
    inp.type       = INPUT_MOUSE;
    inp.mi.dx      = ax;
    inp.mi.dy      = ay;
    inp.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
    SendInput(1, &inp, sizeof(INPUT));
}

void TouchHandler::injectMouseDown(int x, int y) {
    auto [ax, ay] = screenToAbsolute(x, y);

    INPUT inp{};
    inp.type       = INPUT_MOUSE;
    inp.mi.dx      = ax;
    inp.mi.dy      = ay;
    inp.mi.dwFlags = MOUSEEVENTF_LEFTDOWN | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
    SendInput(1, &inp, sizeof(INPUT));
}

void TouchHandler::injectMouseUp(int x, int y) {
    auto [ax, ay] = screenToAbsolute(x, y);

    INPUT inp{};
    inp.type       = INPUT_MOUSE;
    inp.mi.dx      = ax;
    inp.mi.dy      = ay;
    inp.mi.dwFlags = MOUSEEVENTF_LEFTUP | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
    SendInput(1, &inp, sizeof(INPUT));
}

void TouchHandler::injectRightDown(int x, int y) {
    auto [ax, ay] = screenToAbsolute(x, y);

    INPUT inp{};
    inp.type       = INPUT_MOUSE;
    inp.mi.dx      = ax;
    inp.mi.dy      = ay;
    inp.mi.dwFlags = MOUSEEVENTF_RIGHTDOWN | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
    SendInput(1, &inp, sizeof(INPUT));
}

void TouchHandler::injectRightUp(int x, int y) {
    auto [ax, ay] = screenToAbsolute(x, y);

    INPUT inp{};
    inp.type       = INPUT_MOUSE;
    inp.mi.dx      = ax;
    inp.mi.dy      = ay;
    inp.mi.dwFlags = MOUSEEVENTF_RIGHTUP | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
    SendInput(1, &inp, sizeof(INPUT));
}

void TouchHandler::injectScroll(int x, int y, int deltaX, int deltaY) {
    // Move cursor to the scroll position first so the scroll event targets
    // the correct window.
    injectMouseMove(x, y);

    // Vertical scroll (primary).
    if (deltaY != 0) {
        INPUT inp{};
        inp.type         = INPUT_MOUSE;
        inp.mi.dwFlags   = MOUSEEVENTF_WHEEL;
        // Windows WHEEL_DELTA is 120 per "notch".  We scale the pixel delta
        // so it feels natural; the macOS host injects pixel-level scroll
        // events, but Windows expects notch-based units.
        inp.mi.mouseData = static_cast<DWORD>(deltaY * (WHEEL_DELTA / 10));
        SendInput(1, &inp, sizeof(INPUT));
    }

    // Horizontal scroll.
    if (deltaX != 0) {
        INPUT inp{};
        inp.type         = INPUT_MOUSE;
        inp.mi.dwFlags   = MOUSEEVENTF_HWHEEL;
        inp.mi.mouseData = static_cast<DWORD>(deltaX * (WHEEL_DELTA / 10));
        SendInput(1, &inp, sizeof(INPUT));
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
    // Pinch zoom on Windows: hold Ctrl then scroll.
    injectMouseMove(x, y);

    // Press Ctrl.
    INPUT ctrlDown{};
    ctrlDown.type       = INPUT_KEYBOARD;
    ctrlDown.ki.wVk     = VK_CONTROL;
    ctrlDown.ki.dwFlags = 0;
    SendInput(1, &ctrlDown, sizeof(INPUT));

    // Scroll wheel.
    INPUT scroll{};
    scroll.type         = INPUT_MOUSE;
    scroll.mi.dwFlags   = MOUSEEVENTF_WHEEL;
    scroll.mi.mouseData = static_cast<DWORD>(delta * WHEEL_DELTA);
    SendInput(1, &scroll, sizeof(INPUT));

    // Release Ctrl.
    INPUT ctrlUp{};
    ctrlUp.type         = INPUT_KEYBOARD;
    ctrlUp.ki.wVk       = VK_CONTROL;
    ctrlUp.ki.dwFlags   = KEYEVENTF_KEYUP;
    SendInput(1, &ctrlUp, sizeof(INPUT));
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
            momentumVelocityX_ *= Config::MOMENTUM_DECAY;
            momentumVelocityY_ *= Config::MOMENTUM_DECAY;
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(Config::MOMENTUM_INTERVAL_MS));
    }
}
