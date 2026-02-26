#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <mutex>

// Forward declarations — avoid pulling in full Windows/D3D headers
struct ID3D11Device;
struct ID3D11Texture2D;

class VideoEncoder {
public:
    /// Callback signature delivered for every encoded frame.
    /// @param data      Pointer to Annex-B H.265 bitstream (0x00000001 start codes).
    /// @param size      Byte count.
    /// @param timestampNs  Capture timestamp in nanoseconds (pass-through from encode()).
    /// @param isKeyframe   True when the frame contains VPS/SPS/PPS + IDR slice.
    using OutputCallback = std::function<void(const uint8_t* data, size_t size,
                                              uint64_t timestampNs, bool isKeyframe)>;

    virtual ~VideoEncoder() = default;

    // Non-copyable
    VideoEncoder(const VideoEncoder&) = delete;
    VideoEncoder& operator=(const VideoEncoder&) = delete;

    /// Factory — attempts NVENC, then AMF, then QuickSync, then MF software.
    /// Returns nullptr if no encoder is available.
    static std::unique_ptr<VideoEncoder> create(
        ID3D11Device* device, int width, int height, int fps, int bitrateMbps);

    /// Submit a D3D11 texture for encoding.
    /// The texture must be DXGI_FORMAT_B8G8R8A8_UNORM or NV12 depending on backend.
    /// The callback is invoked (possibly synchronously) with the encoded Annex-B data.
    virtual bool encode(ID3D11Texture2D* inputTexture, uint64_t timestampNs) = 0;

    /// Live-update bitrate, quality (0.0-1.0), and gaming-boost flag.
    /// Implementations should apply changes without recreating the session where possible.
    virtual void updateSettings(int bitrateMbps, float quality, bool gamingBoost) = 0;

    /// Flush any buffered frames. Blocks until all pending output has been delivered.
    virtual void flush() = 0;

    /// Human-readable encoder name, e.g. "NVENC", "AMF", "QuickSync".
    virtual std::string encoderName() const = 0;

    // ------------------------------------------------------------------
    // Common helpers
    // ------------------------------------------------------------------
    void setOutputCallback(OutputCallback cb) {
        std::lock_guard<std::mutex> lock(m_cbMutex);
        m_outputCallback = std::move(cb);
    }

    int width()  const { return m_width; }
    int height() const { return m_height; }

protected:
    VideoEncoder() = default;

    /// Derived classes call this to deliver encoded Annex-B data.
    void deliverOutput(const uint8_t* data, size_t size,
                       uint64_t timestampNs, bool isKeyframe) {
        std::lock_guard<std::mutex> lock(m_cbMutex);
        if (m_outputCallback) {
            m_outputCallback(data, size, timestampNs, isKeyframe);
        }
    }

    int m_width  = 0;
    int m_height = 0;
    int m_fps    = 60;
    int m_bitrateMbps = 100;

private:
    std::mutex     m_cbMutex;
    OutputCallback m_outputCallback;
};
