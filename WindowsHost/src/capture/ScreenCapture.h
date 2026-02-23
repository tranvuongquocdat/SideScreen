#pragma once

#include <cstdint>
#include <functional>
#include <atomic>
#include <thread>
#include <mutex>
#include <string>

#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

using Microsoft::WRL::ComPtr;

/// Callback fired when a new frame is captured.
/// @param texture  GPU texture containing the captured frame (valid only during callback).
/// @param timestampNs  Capture timestamp in nanoseconds (QueryPerformanceCounter-based).
using FrameCallback = std::function<void(ID3D11Texture2D* texture, uint64_t timestampNs)>;

/// Captures frames from a Windows display using DXGI Desktop Duplication API.
///
/// Mirrors the macOS ScreenCapture role: delivers GPU-resident frames to an encoder
/// with backpressure (skip if pendingEncodes >= ENCODER_QUEUE_DEPTH).
class ScreenCapture {
public:
    ScreenCapture();
    ~ScreenCapture();

    // Non-copyable, non-movable
    ScreenCapture(const ScreenCapture&) = delete;
    ScreenCapture& operator=(const ScreenCapture&) = delete;

    /// Initialize capture for the Nth display (0-based index).
    /// Creates D3D11 device, enumerates outputs, sets up duplication.
    bool initialize(int displayIndex);

    /// Initialize capture for a specific monitor handle.
    /// Enumerates outputs to find the matching HMONITOR.
    bool initializeForDisplay(HMONITOR monitor);

    /// Start the background capture thread at the given target FPS.
    void startCapture(int targetFps);

    /// Stop the capture thread and release duplication.
    void stop();

    /// Set the callback that receives captured frames.
    void setFrameCallback(FrameCallback cb);

    /// Width of the captured display in pixels.
    int width() const;

    /// Height of the captured display in pixels.
    int height() const;

    /// The D3D11 device used for capture (encoder shares this device).
    ID3D11Device* device() const;

    /// The immediate device context.
    ID3D11DeviceContext* context() const;

    /// Atomic counter for pending encodes — encoder increments before encoding,
    /// decrements when done. Capture checks this for backpressure.
    std::atomic<int32_t> pendingEncodes{0};

private:
    /// Create D3D11 device and get DXGI factory.
    bool createDevice();

    /// Set up IDXGIOutputDuplication for the stored output.
    bool createDuplication();

    /// The capture loop running on m_captureThread.
    void captureLoop();

    /// Log helper (outputs to OutputDebugString / stderr).
    static void log(const char* fmt, ...);

    // D3D11 / DXGI objects
    ComPtr<ID3D11Device>           m_device;
    ComPtr<ID3D11DeviceContext>    m_context;
    ComPtr<IDXGIOutput1>           m_output;
    ComPtr<IDXGIOutputDuplication> m_duplication;

    // Last successfully acquired frame (for idle re-send)
    ComPtr<ID3D11Texture2D>        m_lastFrame;

    // Display info
    DXGI_OUTPUT_DESC               m_outputDesc{};
    int                            m_width  = 0;
    int                            m_height = 0;

    // Capture thread
    std::thread                    m_captureThread;
    std::atomic<bool>              m_running{false};
    int                            m_targetFps = 60;

    // Frame callback
    FrameCallback                  m_frameCallback;
    std::mutex                     m_callbackMutex;
};
