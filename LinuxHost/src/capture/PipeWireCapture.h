#pragma once
#ifdef HAS_PIPEWIRE

#include "capture/ScreenCapture.h"

#include <atomic>
#include <mutex>
#include <thread>
#include <vector>

// Forward declarations — avoid leaking PipeWire headers into every TU
struct pw_thread_loop;
struct pw_context;
struct pw_core;
struct pw_stream;
struct spa_hook;

/**
 * PipeWireCapture — screen capture via the PipeWire ScreenCast portal.
 *
 * Flow:
 *   1. initialize() calls the xdg-desktop-portal ScreenCast D-Bus API
 *      to request a screen-share session and obtain a PipeWire node id.
 *   2. startCapture() connects a pw_stream to that node and enters
 *      the PipeWire thread loop.
 *   3. Frames arrive in on_process(); each frame is forwarded to the
 *      user-supplied FrameCallback.
 *   4. stop() quits the loop and tears down the session.
 *
 * Pixel format:  BGRA or NV12, whatever the compositor provides.
 */
class PipeWireCapture : public ScreenCapture {
public:
    PipeWireCapture();
    ~PipeWireCapture() override;

    bool initialize(int displayIndex) override;
    void startCapture(int targetFps) override;
    void stop() override;
    void setFrameCallback(FrameCallback cb) override;
    int  width()  const override { return m_width.load(std::memory_order_relaxed); }
    int  height() const override { return m_height.load(std::memory_order_relaxed); }

private:
    // Portal D-Bus helpers
    bool requestScreenCastSession(int displayIndex);
    bool openPipeWireRemote();

    // PipeWire stream callbacks (static trampolines → member methods)
    static void onStreamStateChanged(void* data, enum pw_stream_state old,
                                     enum pw_stream_state state, const char* error);
    static void onStreamParamChanged(void* data, uint32_t id,
                                     const struct spa_pod* param);
    static void onStreamProcess(void* data);

    void handleParamChanged(uint32_t id, const struct spa_pod* param);
    void handleProcess();

    // Idle re-send: re-deliver the last frame if nothing new arrives
    void idleResendLoop();

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------
    FrameCallback           m_callback;
    std::mutex              m_callbackMutex;

    std::atomic<int>        m_width{0};
    std::atomic<int>        m_height{0};
    int                     m_stride{0};
    int                     m_targetFps{30};

    // PipeWire objects
    pw_thread_loop*         m_loop{nullptr};
    pw_context*             m_context{nullptr};
    pw_core*                m_core{nullptr};
    pw_stream*              m_stream{nullptr};
    spa_hook*               m_streamListener{nullptr};

    int                     m_pipewireFd{-1};   // PipeWire remote fd
    uint32_t                m_nodeId{0};         // ScreenCast node
    std::string             m_sessionHandle;     // D-Bus session path

    // Capture thread & control
    std::atomic<bool>       m_running{false};
    std::thread             m_idleThread;

    // Last frame buffer for idle re-send
    std::vector<uint8_t>    m_lastFrame;
    std::mutex              m_lastFrameMutex;
    std::atomic<uint64_t>   m_lastFrameTs{0};
};

#endif // HAS_PIPEWIRE
