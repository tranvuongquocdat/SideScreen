#ifdef HAS_X11

#include "capture/X11Capture.h"
#include "Config.h"

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XShm.h>
#include <X11/extensions/Xrandr.h>
#include <X11/extensions/Xcomposite.h>
#include <X11/extensions/Xfixes.h>

#include <sys/ipc.h>
#include <sys/shm.h>
#include <sys/resource.h>
#include <sched.h>

#include <iostream>
#include <cstring>
#include <chrono>
#include <thread>
#include <algorithm>

// =====================================================================
//  Construction / Destruction
// =====================================================================

X11Capture::X11Capture() = default;

X11Capture::~X11Capture() {
    stop();
    freeShm();

    if (m_display) {
        XCloseDisplay(m_display);
        m_display = nullptr;
    }
}

// =====================================================================
//  initialize()
// =====================================================================

bool X11Capture::initialize(int displayIndex) {
    m_display = XOpenDisplay(nullptr);
    if (!m_display) {
        std::cerr << "[X11Capture] Cannot open X display\n";
        return false;
    }

    int screen = DefaultScreen(m_display);
    m_rootWindow = RootWindow(m_display, screen);

    // Query monitor geometry via XRandR
    if (!queryMonitorGeometry(displayIndex)) {
        // Fallback: capture the entire screen
        m_offsetX = 0;
        m_offsetY = 0;
        m_width.store(DisplayWidth(m_display, screen), std::memory_order_relaxed);
        m_height.store(DisplayHeight(m_display, screen), std::memory_order_relaxed);
        std::cout << "[X11Capture] Using full screen: "
                  << m_width.load() << "x" << m_height.load() << "\n";
    }

    m_stride = m_width.load(std::memory_order_relaxed) * 4; // BGRA

    // Try to set up XShm
    if (!initShm()) {
        std::cerr << "[X11Capture] XShm not available, falling back to XGetImage\n";
        m_useShmExtension = false;
    }

    std::cout << "[X11Capture] Initialized: "
              << m_width.load() << "x" << m_height.load()
              << " offset=(" << m_offsetX << "," << m_offsetY << ")"
              << " shm=" << (m_useShmExtension ? "yes" : "no") << "\n";
    return true;
}

// =====================================================================
//  startCapture() / stop()
// =====================================================================

void X11Capture::startCapture(int targetFps) {
    if (m_running.exchange(true))
        return;

    m_targetFps = targetFps;
    m_captureThread = std::thread(&X11Capture::captureLoop, this);

    std::cout << "[X11Capture] Capture started at " << targetFps << " fps\n";
}

void X11Capture::stop() {
    if (!m_running.exchange(false))
        return;

    if (m_captureThread.joinable())
        m_captureThread.join();

    std::cout << "[X11Capture] Stopped\n";
}

void X11Capture::setFrameCallback(FrameCallback cb) {
    std::lock_guard<std::mutex> lock(m_callbackMutex);
    m_callback = std::move(cb);
}

// =====================================================================
//  captureLoop — main capture thread
// =====================================================================

void X11Capture::captureLoop() {
    // Try to elevate thread priority (nice -10)
    setpriority(PRIO_PROCESS, 0, -10);

    // Optionally try SCHED_FIFO (requires CAP_SYS_NICE / root)
    {
        struct sched_param sp;
        sp.sched_priority = 10;
        if (sched_setscheduler(0, SCHED_FIFO, &sp) != 0) {
            // Not fatal; fall back to normal priority
        }
    }

    int w = m_width.load(std::memory_order_relaxed);
    int h = m_height.load(std::memory_order_relaxed);
    int stride = m_stride;

    auto frameDuration = std::chrono::nanoseconds(1'000'000'000LL / m_targetFps);
    auto lastNewFrameTime = std::chrono::steady_clock::now();
    uint64_t idleThresholdNs = static_cast<uint64_t>(2'000'000'000ULL / m_targetFps);

    while (m_running.load(std::memory_order_relaxed)) {
        auto frameStart = std::chrono::steady_clock::now();

        // Back-pressure: skip capture if encoder queue is full
        if (isBackpressured()) {
            std::this_thread::sleep_for(frameDuration);
            continue;
        }

        const uint8_t* pixelData = nullptr;
        bool captured = false;

        // ----------------------------------------------------------
        // Capture via XShm (fast path)
        // ----------------------------------------------------------
        if (m_useShmExtension && m_ximage) {
            XImage* img = static_cast<XImage*>(m_ximage);
            Status ok = XShmGetImage(m_display, m_rootWindow, img,
                                     m_offsetX, m_offsetY, AllPlanes);
            if (ok) {
                pixelData = reinterpret_cast<const uint8_t*>(img->data);
                stride = img->bytes_per_line;
                captured = true;
            }
        }

        // ----------------------------------------------------------
        // Fallback: XGetImage (slow, copies over socket)
        // ----------------------------------------------------------
        if (!captured) {
            XImage* img = XGetImage(m_display, m_rootWindow,
                                    m_offsetX, m_offsetY,
                                    static_cast<unsigned>(w),
                                    static_cast<unsigned>(h),
                                    AllPlanes, ZPixmap);
            if (img) {
                pixelData = reinterpret_cast<const uint8_t*>(img->data);
                stride = img->bytes_per_line;

                // We need to copy because XDestroyImage frees img->data
                size_t frameSize = static_cast<size_t>(stride * h);
                {
                    std::lock_guard<std::mutex> lock(m_lastFrameMutex);
                    m_lastFrame.resize(frameSize);
                    std::memcpy(m_lastFrame.data(), pixelData, frameSize);
                }

                auto now = std::chrono::steady_clock::now();
                uint64_t tsNs = static_cast<uint64_t>(
                    std::chrono::duration_cast<std::chrono::nanoseconds>(
                        now.time_since_epoch()).count());
                m_lastFrameTs.store(tsNs, std::memory_order_release);
                lastNewFrameTime = now;

                {
                    std::lock_guard<std::mutex> lock(m_callbackMutex);
                    if (m_callback) {
                        m_callback(m_lastFrame.data(), w, h, stride, tsNs);
                    }
                }

                XDestroyImage(img);

                // Sleep for remainder of frame interval
                auto elapsed = std::chrono::steady_clock::now() - frameStart;
                if (elapsed < frameDuration)
                    std::this_thread::sleep_for(frameDuration - elapsed);
                continue;
            }
        }

        // ----------------------------------------------------------
        // Deliver XShm-captured frame
        // ----------------------------------------------------------
        if (captured && pixelData) {
            auto now = std::chrono::steady_clock::now();
            uint64_t tsNs = static_cast<uint64_t>(
                std::chrono::duration_cast<std::chrono::nanoseconds>(
                    now.time_since_epoch()).count());

            // Save for idle re-send
            {
                std::lock_guard<std::mutex> lock(m_lastFrameMutex);
                size_t frameSize = static_cast<size_t>(stride * h);
                m_lastFrame.resize(frameSize);
                std::memcpy(m_lastFrame.data(), pixelData, frameSize);
            }
            m_lastFrameTs.store(tsNs, std::memory_order_release);
            lastNewFrameTime = now;

            {
                std::lock_guard<std::mutex> lock(m_callbackMutex);
                if (m_callback) {
                    m_callback(pixelData, w, h, stride, tsNs);
                }
            }
        } else {
            // ----------------------------------------------------------
            // Idle re-send: no new frame captured, re-deliver last
            // ----------------------------------------------------------
            auto now = std::chrono::steady_clock::now();
            uint64_t nowNs = static_cast<uint64_t>(
                std::chrono::duration_cast<std::chrono::nanoseconds>(
                    now.time_since_epoch()).count());
            uint64_t lastTs = m_lastFrameTs.load(std::memory_order_acquire);

            if (lastTs > 0 && (nowNs - lastTs) > idleThresholdNs) {
                std::lock_guard<std::mutex> frameLock(m_lastFrameMutex);
                if (!m_lastFrame.empty()) {
                    std::lock_guard<std::mutex> cbLock(m_callbackMutex);
                    if (m_callback) {
                        m_callback(m_lastFrame.data(), w, h, stride, nowNs);
                    }
                }
            }
        }

        // Sleep for remainder of frame interval
        auto elapsed = std::chrono::steady_clock::now() - frameStart;
        if (elapsed < frameDuration)
            std::this_thread::sleep_for(frameDuration - elapsed);
    }
}

// =====================================================================
//  XShm setup
// =====================================================================

bool X11Capture::initShm() {
    if (!XShmQueryExtension(m_display))
        return false;

    int w = m_width.load(std::memory_order_relaxed);
    int h = m_height.load(std::memory_order_relaxed);
    int screen = DefaultScreen(m_display);
    int depth = DefaultDepth(m_display, screen);

    m_shmInfo = new XShmSegmentInfo;
    std::memset(m_shmInfo, 0, sizeof(XShmSegmentInfo));

    XImage* img = XShmCreateImage(m_display,
        DefaultVisual(m_display, screen),
        static_cast<unsigned>(depth),
        ZPixmap, nullptr,
        m_shmInfo,
        static_cast<unsigned>(w),
        static_cast<unsigned>(h));

    if (!img) {
        delete m_shmInfo;
        m_shmInfo = nullptr;
        return false;
    }

    m_shmInfo->shmid = shmget(IPC_PRIVATE,
        static_cast<size_t>(img->bytes_per_line * img->height),
        IPC_CREAT | 0600);

    if (m_shmInfo->shmid < 0) {
        XDestroyImage(img);
        delete m_shmInfo;
        m_shmInfo = nullptr;
        return false;
    }

    m_shmInfo->shmaddr = static_cast<char*>(shmat(m_shmInfo->shmid, nullptr, 0));
    if (m_shmInfo->shmaddr == reinterpret_cast<char*>(-1)) {
        shmctl(m_shmInfo->shmid, IPC_RMID, nullptr);
        XDestroyImage(img);
        delete m_shmInfo;
        m_shmInfo = nullptr;
        return false;
    }
    img->data = m_shmInfo->shmaddr;
    m_shmInfo->readOnly = False;

    if (!XShmAttach(m_display, m_shmInfo)) {
        shmdt(m_shmInfo->shmaddr);
        shmctl(m_shmInfo->shmid, IPC_RMID, nullptr);
        XDestroyImage(img);
        delete m_shmInfo;
        m_shmInfo = nullptr;
        return false;
    }

    // Mark for removal once all processes detach
    shmctl(m_shmInfo->shmid, IPC_RMID, nullptr);

    m_ximage = img;
    m_useShmExtension = true;
    m_stride = img->bytes_per_line;

    std::cout << "[X11Capture] XShm segment attached, stride=" << m_stride << "\n";
    return true;
}

void X11Capture::freeShm() {
    if (m_ximage) {
        XImage* img = static_cast<XImage*>(m_ximage);
        if (m_shmInfo && m_display) {
            XShmDetach(m_display, m_shmInfo);
        }
        // XDestroyImage also frees img->data, but since it points to
        // shared memory we need to detach first.
        img->data = nullptr; // prevent double-free
        XDestroyImage(img);
        m_ximage = nullptr;
    }

    if (m_shmInfo) {
        if (m_shmInfo->shmaddr && m_shmInfo->shmaddr != reinterpret_cast<char*>(-1)) {
            shmdt(m_shmInfo->shmaddr);
        }
        delete m_shmInfo;
        m_shmInfo = nullptr;
    }
}

// =====================================================================
//  XRandR monitor geometry
// =====================================================================

bool X11Capture::queryMonitorGeometry(int displayIndex) {
    int screen = DefaultScreen(m_display);
    Window root = RootWindow(m_display, screen);

    int nMonitors = 0;
    XRRMonitorInfo* monitors = XRRGetMonitors(m_display, root, True, &nMonitors);
    if (!monitors || nMonitors <= 0) {
        if (monitors) XRRFreeMonitors(monitors);
        return false;
    }

    int idx = std::clamp(displayIndex, 0, nMonitors - 1);
    XRRMonitorInfo& mon = monitors[idx];

    m_offsetX = mon.x;
    m_offsetY = mon.y;
    m_width.store(mon.width, std::memory_order_relaxed);
    m_height.store(mon.height, std::memory_order_relaxed);

    std::cout << "[X11Capture] Monitor " << idx << ": "
              << mon.width << "x" << mon.height
              << " at (" << mon.x << "," << mon.y << ")\n";

    XRRFreeMonitors(monitors);
    return true;
}

#endif // HAS_X11
