#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <mutex>

/// Abstract base class for H.265 video encoders on Linux.
///
/// Output format: Annex-B H.265 (0x00000001 start codes), with VPS/SPS/PPS
/// prepended to every keyframe.  All-intra (every frame IDR, GOP=1),
/// no B-frames, zero latency / low delay.  Matches macOS VideoToolbox and
/// Windows NVENC settings used in SideScreen.
class VideoEncoder {
public:
    /// Callback signature delivered for every encoded frame.
    /// @param data        Pointer to Annex-B H.265 bitstream (0x00000001 start codes).
    /// @param size        Byte count.
    /// @param timestampNs Capture timestamp in nanoseconds (pass-through from encode()).
    /// @param isKeyframe  True when the frame contains VPS/SPS/PPS + IDR slice.
    using OutputCallback = std::function<void(const uint8_t* data, size_t size,
                                              uint64_t timestampNs, bool isKeyframe)>;

    virtual ~VideoEncoder() = default;

    // Non-copyable
    VideoEncoder(const VideoEncoder&) = delete;
    VideoEncoder& operator=(const VideoEncoder&) = delete;

    /// Factory — attempts VaapiEncoder, then FFmpegEncoder.
    /// Returns nullptr if no encoder is available.
    static std::unique_ptr<VideoEncoder> create(
        int width, int height, int fps, int bitrateMbps);

    /// Submit raw BGRA pixel data for encoding.
    /// @param pixelData   Pointer to BGRA pixel buffer.
    /// @param width       Frame width in pixels.
    /// @param height      Frame height in pixels.
    /// @param stride      Row stride in bytes (typically width * 4 for BGRA).
    /// @param timestampNs Capture timestamp in nanoseconds.
    /// @return true on success.
    virtual bool encode(const uint8_t* pixelData, int width, int height,
                        int stride, uint64_t timestampNs) = 0;

    /// Live-update bitrate, quality (0.0-1.0), and gaming-boost flag.
    /// Implementations should apply changes without recreating the session where possible.
    virtual void updateSettings(int bitrateMbps, float quality, bool gamingBoost) = 0;

    /// Flush any buffered frames.  Blocks until all pending output has been delivered.
    virtual void flush() = 0;

    /// Human-readable encoder name, e.g. "VA-API", "FFmpeg (hevc_vaapi)".
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

    int m_width       = 0;
    int m_height      = 0;
    int m_fps         = 60;
    int m_bitrateMbps = 100;

private:
    std::mutex     m_cbMutex;
    OutputCallback m_outputCallback;
};
