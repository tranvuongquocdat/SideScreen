#include "ScreenCapture.h"
#include "../Config.h"

#include <cstdarg>
#include <cstdio>
#include <chrono>

// Windows headers for COM, OutputDebugString, thread priority
#include <Windows.h>
#include <comdef.h>

// Link required libraries
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Get current time in nanoseconds from QueryPerformanceCounter.
static uint64_t nowNs() {
    static LARGE_INTEGER freq{};
    if (freq.QuadPart == 0) {
        QueryPerformanceFrequency(&freq);
    }
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    // Convert to nanoseconds: (count * 1e9) / freq
    return static_cast<uint64_t>(
        static_cast<double>(now.QuadPart) * 1'000'000'000.0 / static_cast<double>(freq.QuadPart));
}

// ---------------------------------------------------------------------------
// Construction / Destruction
// ---------------------------------------------------------------------------

ScreenCapture::ScreenCapture() = default;

ScreenCapture::~ScreenCapture() {
    stop();
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

void ScreenCapture::log(const char* fmt, ...) {
    char buf[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);

    // Write to debugger output
    OutputDebugStringA("[ScreenCapture] ");
    OutputDebugStringA(buf);
    OutputDebugStringA("\n");

    // Also to stderr for console builds
    fprintf(stderr, "[ScreenCapture] %s\n", buf);
}

// ---------------------------------------------------------------------------
// D3D11 Device Creation
// ---------------------------------------------------------------------------

bool ScreenCapture::createDevice() {
    D3D_FEATURE_LEVEL featureLevels[] = {
        D3D_FEATURE_LEVEL_11_1,
        D3D_FEATURE_LEVEL_11_0,
    };

    UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
#ifdef _DEBUG
    flags |= D3D11_CREATE_DEVICE_DEBUG;
#endif

    D3D_FEATURE_LEVEL featureLevel{};
    HRESULT hr = D3D11CreateDevice(
        nullptr,                        // default adapter
        D3D_DRIVER_TYPE_HARDWARE,
        nullptr,                        // no software rasterizer
        flags,
        featureLevels,
        ARRAYSIZE(featureLevels),
        D3D11_SDK_VERSION,
        m_device.GetAddressOf(),
        &featureLevel,
        m_context.GetAddressOf());

    if (FAILED(hr)) {
        log("D3D11CreateDevice failed: 0x%08X", hr);
        return false;
    }

    log("D3D11 device created, feature level: 0x%X", static_cast<int>(featureLevel));
    return true;
}

// ---------------------------------------------------------------------------
// DXGI Output Duplication
// ---------------------------------------------------------------------------

bool ScreenCapture::createDuplication() {
    if (!m_output) {
        log("No output set — cannot create duplication");
        return false;
    }

    // Release any previous duplication
    m_duplication.Reset();

    HRESULT hr = m_output->DuplicateOutput(m_device.Get(), m_duplication.GetAddressOf());
    if (FAILED(hr)) {
        log("DuplicateOutput failed: 0x%08X", hr);
        if (hr == E_ACCESSDENIED) {
            log("  Access denied — another app may be duplicating this output, "
                "or the desktop is on a secure/UAC screen.");
        }
        return false;
    }

    log("Desktop duplication created successfully");
    return true;
}

// ---------------------------------------------------------------------------
// initialize(displayIndex)
// ---------------------------------------------------------------------------

bool ScreenCapture::initialize(int displayIndex) {
    if (!createDevice()) return false;

    // Get DXGI device → adapter → enumerate outputs
    ComPtr<IDXGIDevice> dxgiDevice;
    HRESULT hr = m_device.As(&dxgiDevice);
    if (FAILED(hr)) {
        log("QueryInterface for IDXGIDevice failed: 0x%08X", hr);
        return false;
    }

    ComPtr<IDXGIAdapter> adapter;
    hr = dxgiDevice->GetAdapter(adapter.GetAddressOf());
    if (FAILED(hr)) {
        log("GetAdapter failed: 0x%08X", hr);
        return false;
    }

    // Enumerate outputs to find the requested display index
    ComPtr<IDXGIOutput> output;
    int currentIndex = 0;

    // Walk all adapters if needed (multi-GPU)
    ComPtr<IDXGIFactory1> factory;
    hr = adapter->GetParent(__uuidof(IDXGIFactory1), reinterpret_cast<void**>(factory.GetAddressOf()));
    if (FAILED(hr)) {
        log("GetParent(IDXGIFactory1) failed: 0x%08X", hr);
        return false;
    }

    bool found = false;
    for (UINT adapterIdx = 0; !found; ++adapterIdx) {
        ComPtr<IDXGIAdapter1> enumAdapter;
        hr = factory->EnumAdapters1(adapterIdx, enumAdapter.GetAddressOf());
        if (hr == DXGI_ERROR_NOT_FOUND) break;

        for (UINT outputIdx = 0; ; ++outputIdx) {
            ComPtr<IDXGIOutput> enumOutput;
            hr = enumAdapter->EnumOutputs(outputIdx, enumOutput.GetAddressOf());
            if (hr == DXGI_ERROR_NOT_FOUND) break;

            if (currentIndex == displayIndex) {
                output = enumOutput;
                found = true;
                break;
            }
            ++currentIndex;
        }
    }

    if (!output) {
        log("Display index %d not found (%d displays enumerated)", displayIndex, currentIndex);
        return false;
    }

    // Get output description for dimensions
    hr = output->GetDesc(&m_outputDesc);
    if (FAILED(hr)) {
        log("GetDesc failed: 0x%08X", hr);
        return false;
    }

    m_width  = m_outputDesc.DesktopCoordinates.right  - m_outputDesc.DesktopCoordinates.left;
    m_height = m_outputDesc.DesktopCoordinates.bottom - m_outputDesc.DesktopCoordinates.top;
    log("Display %d: %dx%d", displayIndex, m_width, m_height);

    // QI for IDXGIOutput1 (required for DuplicateOutput)
    hr = output.As(&m_output);
    if (FAILED(hr)) {
        log("QueryInterface for IDXGIOutput1 failed: 0x%08X", hr);
        return false;
    }

    return createDuplication();
}

// ---------------------------------------------------------------------------
// initializeForDisplay(HMONITOR)
// ---------------------------------------------------------------------------

bool ScreenCapture::initializeForDisplay(HMONITOR monitor) {
    if (!createDevice()) return false;

    ComPtr<IDXGIDevice> dxgiDevice;
    HRESULT hr = m_device.As(&dxgiDevice);
    if (FAILED(hr)) return false;

    ComPtr<IDXGIAdapter> adapter;
    hr = dxgiDevice->GetAdapter(adapter.GetAddressOf());
    if (FAILED(hr)) return false;

    ComPtr<IDXGIFactory1> factory;
    hr = adapter->GetParent(__uuidof(IDXGIFactory1), reinterpret_cast<void**>(factory.GetAddressOf()));
    if (FAILED(hr)) return false;

    bool found = false;
    for (UINT adapterIdx = 0; !found; ++adapterIdx) {
        ComPtr<IDXGIAdapter1> enumAdapter;
        hr = factory->EnumAdapters1(adapterIdx, enumAdapter.GetAddressOf());
        if (hr == DXGI_ERROR_NOT_FOUND) break;

        for (UINT outputIdx = 0; ; ++outputIdx) {
            ComPtr<IDXGIOutput> enumOutput;
            hr = enumAdapter->EnumOutputs(outputIdx, enumOutput.GetAddressOf());
            if (hr == DXGI_ERROR_NOT_FOUND) break;

            DXGI_OUTPUT_DESC desc{};
            enumOutput->GetDesc(&desc);
            if (desc.Monitor == monitor) {
                m_outputDesc = desc;
                m_width  = desc.DesktopCoordinates.right  - desc.DesktopCoordinates.left;
                m_height = desc.DesktopCoordinates.bottom - desc.DesktopCoordinates.top;

                hr = enumOutput.As(&m_output);
                if (FAILED(hr)) {
                    log("QI for IDXGIOutput1 failed: 0x%08X", hr);
                    return false;
                }
                found = true;
                break;
            }
        }
    }

    if (!found) {
        log("HMONITOR 0x%p not found among DXGI outputs", monitor);
        return false;
    }

    log("Display for monitor 0x%p: %dx%d", monitor, m_width, m_height);
    return createDuplication();
}

// ---------------------------------------------------------------------------
// startCapture / stop
// ---------------------------------------------------------------------------

void ScreenCapture::startCapture(int targetFps) {
    if (m_running.load()) {
        log("Capture already running");
        return;
    }

    m_targetFps = (targetFps > 0) ? targetFps : 60;
    m_running.store(true);

    m_captureThread = std::thread([this]() {
        captureLoop();
    });

    log("Capture started at target %d FPS", m_targetFps);
}

void ScreenCapture::stop() {
    if (!m_running.load()) return;

    m_running.store(false);

    if (m_captureThread.joinable()) {
        m_captureThread.join();
    }

    // Release duplication and last-frame reference
    m_duplication.Reset();
    m_lastFrame.Reset();

    log("Capture stopped");
}

// ---------------------------------------------------------------------------
// Callback / accessors
// ---------------------------------------------------------------------------

void ScreenCapture::setFrameCallback(FrameCallback cb) {
    std::lock_guard<std::mutex> lock(m_callbackMutex);
    m_frameCallback = std::move(cb);
}

int  ScreenCapture::width()   const { return m_width;  }
int  ScreenCapture::height()  const { return m_height; }
ID3D11Device*        ScreenCapture::device()  const { return m_device.Get();  }
ID3D11DeviceContext* ScreenCapture::context() const { return m_context.Get(); }

// ---------------------------------------------------------------------------
// Capture Loop
// ---------------------------------------------------------------------------

void ScreenCapture::captureLoop() {
    // COM initialization for this thread (MTA)
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr)) {
        log("CoInitializeEx failed: 0x%08X", hr);
        return;
    }

    // Raise thread priority for low-latency capture
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST);

    const auto frameDuration = std::chrono::microseconds(1'000'000 / m_targetFps);
    auto nextFrameTime = std::chrono::steady_clock::now();

    while (m_running.load(std::memory_order_relaxed)) {
        // Frame pacing: sleep until next target frame time
        auto now = std::chrono::steady_clock::now();
        if (now < nextFrameTime) {
            std::this_thread::sleep_until(nextFrameTime);
        }
        nextFrameTime += frameDuration;

        // Backpressure: skip frame if encoder is saturated
        if (pendingEncodes.load(std::memory_order_acquire) >= Config::ENCODER_QUEUE_DEPTH) {
            continue;
        }

        // No duplication? Try to recreate (may have been lost).
        if (!m_duplication) {
            if (!createDuplication()) {
                // Wait a bit before retrying
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
                continue;
            }
        }

        // Acquire next frame
        ComPtr<IDXGIResource> desktopResource;
        DXGI_OUTDUPL_FRAME_INFO frameInfo{};

        // Use a short timeout so we can check m_running frequently
        hr = m_duplication->AcquireNextFrame(16, &frameInfo, desktopResource.GetAddressOf());

        if (hr == DXGI_ERROR_WAIT_TIMEOUT) {
            // No new frame — re-send last captured frame (idle screen, like macOS behavior).
            // This keeps the encoder fed so the client sees updates if bitrate/quality changes.
            if (m_lastFrame) {
                uint64_t ts = nowNs();
                std::lock_guard<std::mutex> lock(m_callbackMutex);
                if (m_frameCallback) {
                    m_frameCallback(m_lastFrame.Get(), ts);
                }
            }
            continue;
        }

        if (hr == DXGI_ERROR_ACCESS_LOST) {
            // Display mode changed, desktop switch, or fullscreen transition.
            // Release and recreate on next iteration.
            log("Desktop duplication access lost — will recreate");
            m_duplication.Reset();
            m_lastFrame.Reset();
            continue;
        }

        if (FAILED(hr)) {
            log("AcquireNextFrame failed: 0x%08X", hr);
            // For unexpected errors, release and attempt recovery
            m_duplication.Reset();
            m_lastFrame.Reset();
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            continue;
        }

        // Got a new frame — extract the texture
        ComPtr<ID3D11Texture2D> frameTexture;
        hr = desktopResource.As(&frameTexture);
        if (FAILED(hr)) {
            log("QI for ID3D11Texture2D failed: 0x%08X", hr);
            m_duplication->ReleaseFrame();
            continue;
        }

        // The desktop texture from DXGI duplication is only valid until ReleaseFrame().
        // We must copy it to our own staging texture so the encoder can work on it
        // asynchronously without racing with the next AcquireNextFrame.
        D3D11_TEXTURE2D_DESC desc{};
        frameTexture->GetDesc(&desc);

        // Create or recreate our copy texture if dimensions/format changed
        bool needNewCopy = !m_lastFrame;
        if (m_lastFrame) {
            D3D11_TEXTURE2D_DESC lastDesc{};
            m_lastFrame->GetDesc(&lastDesc);
            if (lastDesc.Width != desc.Width || lastDesc.Height != desc.Height ||
                lastDesc.Format != desc.Format) {
                needNewCopy = true;
            }
        }

        if (needNewCopy) {
            D3D11_TEXTURE2D_DESC copyDesc{};
            copyDesc.Width              = desc.Width;
            copyDesc.Height             = desc.Height;
            copyDesc.MipLevels          = 1;
            copyDesc.ArraySize          = 1;
            copyDesc.Format             = desc.Format;
            copyDesc.SampleDesc.Count   = 1;
            copyDesc.SampleDesc.Quality = 0;
            copyDesc.Usage              = D3D11_USAGE_DEFAULT;
            copyDesc.BindFlags          = 0;
            copyDesc.CPUAccessFlags     = 0;
            copyDesc.MiscFlags          = 0;

            m_lastFrame.Reset();
            hr = m_device->CreateTexture2D(&copyDesc, nullptr, m_lastFrame.GetAddressOf());
            if (FAILED(hr)) {
                log("CreateTexture2D (copy) failed: 0x%08X", hr);
                m_duplication->ReleaseFrame();
                continue;
            }

            // Update dimensions in case they changed (resolution change)
            m_width  = static_cast<int>(desc.Width);
            m_height = static_cast<int>(desc.Height);
        }

        // GPU-side copy (fast, no CPU readback)
        m_context->CopyResource(m_lastFrame.Get(), frameTexture.Get());

        // Release the DXGI frame as soon as possible
        m_duplication->ReleaseFrame();

        // Fire callback with our owned copy
        uint64_t ts = nowNs();
        {
            std::lock_guard<std::mutex> lock(m_callbackMutex);
            if (m_frameCallback) {
                m_frameCallback(m_lastFrame.Get(), ts);
            }
        }
    }

    CoUninitialize();
}
