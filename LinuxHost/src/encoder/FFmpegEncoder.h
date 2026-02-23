#pragma once

#ifdef HAS_FFMPEG

#include "VideoEncoder.h"
#include <string>
#include <vector>
#include <cstdint>

// FFmpeg headers (C linkage)
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/pixfmt.h>
#include <libavcodec/bsf.h>
}

/// FFmpeg-based H.265/HEVC encoder — portable fallback.
///
/// Tries hardware-accelerated encoders in order:
///   1. hevc_vaapi  — Intel/AMD via VA-API
///   2. hevc_nvenc  — NVIDIA
///   3. hevc_qsv    — Intel QuickSync
///   4. libx265     — Software (always available if FFmpeg was compiled with it)
///
/// Configuration matches macOS/Windows:
///   - All-intra (gop_size=1, every frame IDR)
///   - No B-frames (max_b_frames=0)
///   - Low-delay
///   - HEVC Main profile
///   - Annex-B output with VPS/SPS/PPS on every keyframe
class FFmpegEncoder : public VideoEncoder {
public:
    FFmpegEncoder();
    ~FFmpegEncoder() override;

    /// Try to open one of the supported HEVC encoders.
    /// Returns false if no encoder is available.
    bool initialize(int width, int height, int fps, int bitrateMbps);

    bool encode(const uint8_t* pixelData, int width, int height,
                int stride, uint64_t timestampNs) override;
    void updateSettings(int bitrateMbps, float quality, bool gamingBoost) override;
    void flush() override;
    std::string encoderName() const override;

private:
    void destroy();

    /// Try to open a specific encoder by name.
    bool tryEncoder(const char* name, int width, int height,
                    int fps, int bitrateMbps);

    /// Receive encoded packets and deliver via callback.
    bool receivePackets(uint64_t timestampNs);

    // FFmpeg objects
    const AVCodec*      m_codec      = nullptr;
    AVCodecContext*      m_codecCtx   = nullptr;
    AVFrame*            m_frame      = nullptr;
    AVPacket*           m_packet     = nullptr;
    AVBSFContext*       m_bsfCtx     = nullptr;  // bitstream filter (if needed for Annex-B)

    // For VA-API HW encoders: device context
    AVBufferRef*        m_hwDeviceCtx  = nullptr;
    AVBufferRef*        m_hwFramesCtx  = nullptr;
    AVFrame*            m_hwFrame      = nullptr;  // hardware surface frame

    // State
    std::string m_encoderName;
    bool        m_initialized = false;
    bool        m_isHwEncoder = false;
    int64_t     m_frameIndex  = 0;
};

#endif // HAS_FFMPEG
