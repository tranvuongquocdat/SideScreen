#pragma once
#ifdef HAS_X11

#include "capture/ScreenCapture.h"

#include <atomic>
#include <mutex>
#include <thread>
#include <vector>

// Forward declarations — avoid leaking X11 headers everywhere
typedef struct _XDisplay Display;
typedef unsigned long XID;
typedef XID Pixmap;

// XShm types
struct XShmSegmentInfo;

/**
 * X11Capture — screen capture via XShm (shared memory) on X11.
 *
 * Uses XShmGetImage for zero-copy capture from the root window or
 * a composited off-screen pixmap (XComposite). Falls back to
 * XGetImage if XShm is unavailable.
 *
 * Output format: BGRA (32-bit, matching X11's ZPixmap with depth 24/32).
 */
class X11Capture : public ScreenCapture {
public:
    X11Capture();
    ~X11Capture() override;

    bool initialize(int displayIndex) override;
    void startCapture(int targetFps) override;
    void stop() override;
    void setFrameCallback(FrameCallback cb) override;
    int  width()  const override { return m_width.load(std::memory_order_relaxed); }
    int  height() const override { return m_height.load(std::memory_order_relaxed); }

private:
    // Capture loop (runs on m_captureThread)
    void captureLoop();

    // XShm setup/teardown
    bool initShm();
    void freeShm();

    // XRandR monitor geometry lookup
    bool queryMonitorGeometry(int displayIndex);

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------
    FrameCallback           m_callback;
    std::mutex              m_callbackMutex;

    std::atomic<int>        m_width{0};
    std::atomic<int>        m_height{0};
    int                     m_stride{0};
    int                     m_targetFps{30};

    // Monitor region (for multi-monitor setups)
    int                     m_offsetX{0};
    int                     m_offsetY{0};

    // X11 objects
    Display*                m_display{nullptr};
    XID                     m_rootWindow{0};
    void*                   m_ximage{nullptr};   // XImage* (opaque to avoid X11 header leak)

    // XShm
    XShmSegmentInfo*        m_shmInfo{nullptr};
    bool                    m_useShmExtension{false};

    // Capture thread & control
    std::atomic<bool>       m_running{false};
    std::thread             m_captureThread;

    // Last frame buffer for idle re-send
    std::vector<uint8_t>    m_lastFrame;
    std::mutex              m_lastFrameMutex;
    std::atomic<uint64_t>   m_lastFrameTs{0};
};

#endif // HAS_X11
