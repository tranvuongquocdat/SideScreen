// FFmpegEncoder.cpp — FFmpeg libavcodec H.265 encoder (portable fallback)
//
// Tries hardware encoders first, falls back to software libx265.
// Output: Annex-B H.265 with 0x00000001 start codes.
//
// Matching macOS VideoToolbox / Windows NVENC settings:
//   - All-intra (gop_size=1, every frame IDR)
//   - No B-frames
//   - Low-delay / zero latency
//   - HEVC Main profile
//   - VPS/SPS/PPS on every keyframe

#ifdef HAS_FFMPEG

#include "FFmpegEncoder.h"
#include "../Config.h"

#include <cstdio>
#include <cstring>
#include <algorithm>

extern "C" {
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Check if a NAL unit stream is already in Annex-B format.
static bool isAnnexB(const uint8_t* data, size_t size) {
    if (size < 4) return false;
    return (data[0] == 0x00 && data[1] == 0x00 &&
            data[2] == 0x00 && data[3] == 0x01) ||
           (data[0] == 0x00 && data[1] == 0x00 && data[2] == 0x01);
}

/// BGRA to NV12 conversion (BT.601) into AVFrame planes.
static void bgraToNV12(const uint8_t* bgra, int width, int height, int srcStride,
                       uint8_t* yPlane, int yLinesize,
                       uint8_t* uvPlane, int uvLinesize)
{
    // Y plane
    for (int y = 0; y < height; ++y) {
        const uint8_t* row = bgra + y * srcStride;
        uint8_t* yRow = yPlane + y * yLinesize;
        for (int x = 0; x < width; ++x) {
            uint8_t b = row[x * 4 + 0];
            uint8_t g = row[x * 4 + 1];
            uint8_t r = row[x * 4 + 2];
            int yVal = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
            yRow[x] = static_cast<uint8_t>(std::clamp(yVal, 0, 255));
        }
    }

    // UV plane (NV12: interleaved U,V, half resolution)
    for (int y = 0; y < height / 2; ++y) {
        const uint8_t* row0 = bgra + (y * 2) * srcStride;
        const uint8_t* row1 = bgra + (y * 2 + 1) * srcStride;
        uint8_t* uvRow = uvPlane + y * uvLinesize;
        for (int x = 0; x < width / 2; ++x) {
            int b = 0, g = 0, r = 0;
            for (int dy = 0; dy < 2; ++dy) {
                const uint8_t* src = (dy == 0) ? row0 : row1;
                for (int dx = 0; dx < 2; ++dx) {
                    int px = (x * 2 + dx) * 4;
                    b += src[px + 0];
                    g += src[px + 1];
                    r += src[px + 2];
                }
            }
            b /= 4; g /= 4; r /= 4;

            int u = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
            int v = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
            uvRow[x * 2 + 0] = static_cast<uint8_t>(std::clamp(u, 0, 255));
            uvRow[x * 2 + 1] = static_cast<uint8_t>(std::clamp(v, 0, 255));
        }
    }
}

// ---------------------------------------------------------------------------
// Ctor / Dtor
// ---------------------------------------------------------------------------
FFmpegEncoder::FFmpegEncoder() = default;

FFmpegEncoder::~FFmpegEncoder() {
    destroy();
}

// ---------------------------------------------------------------------------
// tryEncoder
// ---------------------------------------------------------------------------
bool FFmpegEncoder::tryEncoder(const char* name, int width, int height,
                               int fps, int bitrateMbps)
{
    // Clean up any previous attempt
    destroy();

    m_codec = avcodec_find_encoder_by_name(name);
    if (!m_codec) {
        printf("[FFmpeg] Encoder '%s' not found\n", name);
        return false;
    }

    m_codecCtx = avcodec_alloc_context3(m_codec);
    if (!m_codecCtx) {
        printf("[FFmpeg] Failed to allocate codec context for '%s'\n", name);
        return false;
    }

    // Determine if this is a hardware encoder
    m_isHwEncoder = false;
    bool isVaapiEncoder = (strcmp(name, "hevc_vaapi") == 0);
    bool isNvencEncoder = (strcmp(name, "hevc_nvenc") == 0);
    bool isQsvEncoder   = (strcmp(name, "hevc_qsv") == 0);
    m_isHwEncoder = isVaapiEncoder || isNvencEncoder || isQsvEncoder;

    // --- Configure codec context ---
    m_codecCtx->width     = width;
    m_codecCtx->height    = height;
    m_codecCtx->time_base = AVRational{1, fps};
    m_codecCtx->framerate = AVRational{fps, 1};

    // Bitrate
    m_codecCtx->bit_rate     = static_cast<int64_t>(bitrateMbps) * 1'000'000LL;
    m_codecCtx->rc_max_rate  = static_cast<int64_t>(bitrateMbps) * 1'500'000LL;
    m_codecCtx->rc_buffer_size = static_cast<int>(bitrateMbps) * 1'000'000;

    // All-intra, no B-frames (matching macOS/Windows)
    m_codecCtx->gop_size     = 1;    // every frame is IDR
    m_codecCtx->max_b_frames = 0;    // no B-frames
    m_codecCtx->flags        |= AV_CODEC_FLAG_LOW_DELAY;

    // Request global header OFF — we want Annex-B (start codes in-stream)
    m_codecCtx->flags &= ~AV_CODEC_FLAG_GLOBAL_HEADER;

    // Profile: Main
    m_codecCtx->profile = FF_PROFILE_HEVC_MAIN;

    // Thread count
    m_codecCtx->thread_count = 1; // low latency, single-threaded

    // --- Hardware-specific setup ---
    if (isVaapiEncoder) {
        // Create VA-API device context
        int ret = av_hwdevice_ctx_create(&m_hwDeviceCtx,
                                         AV_HWDEVICE_TYPE_VAAPI,
                                         "/dev/dri/renderD128", nullptr, 0);
        if (ret < 0) {
            printf("[FFmpeg] Failed to create VA-API device context: %d\n", ret);
            destroy();
            return false;
        }

        // Set pixel format for VA-API
        m_codecCtx->pix_fmt = AV_PIX_FMT_VAAPI;

        // Create hardware frames context
        m_hwFramesCtx = av_hwframe_ctx_alloc(m_hwDeviceCtx);
        if (!m_hwFramesCtx) {
            printf("[FFmpeg] Failed to allocate HW frames context\n");
            destroy();
            return false;
        }

        auto* framesCtx = reinterpret_cast<AVHWFramesContext*>(m_hwFramesCtx->data);
        framesCtx->format    = AV_PIX_FMT_VAAPI;
        framesCtx->sw_format = AV_PIX_FMT_NV12;
        framesCtx->width     = width;
        framesCtx->height    = height;
        framesCtx->initial_pool_size = 4;

        int ret2 = av_hwframe_ctx_init(m_hwFramesCtx);
        if (ret2 < 0) {
            printf("[FFmpeg] Failed to init HW frames context: %d\n", ret2);
            destroy();
            return false;
        }

        m_codecCtx->hw_frames_ctx = av_buffer_ref(m_hwFramesCtx);

    } else if (isNvencEncoder) {
        m_codecCtx->pix_fmt = AV_PIX_FMT_NV12;

        // NVENC-specific options
        av_opt_set(m_codecCtx->priv_data, "preset", "p1", 0);    // fastest
        av_opt_set(m_codecCtx->priv_data, "tune", "ull", 0);     // ultra low latency
        av_opt_set(m_codecCtx->priv_data, "rc", "vbr", 0);
        av_opt_set(m_codecCtx->priv_data, "forced-idr", "1", 0);

    } else if (isQsvEncoder) {
        m_codecCtx->pix_fmt = AV_PIX_FMT_NV12;

        av_opt_set(m_codecCtx->priv_data, "preset", "veryfast", 0);
        av_opt_set(m_codecCtx->priv_data, "forced_idr", "1", 0);

    } else {
        // Software encoder (libx265)
        m_codecCtx->pix_fmt = AV_PIX_FMT_YUV420P;

        // libx265-specific options for zero latency
        av_opt_set(m_codecCtx->priv_data, "preset", "ultrafast", 0);
        av_opt_set(m_codecCtx->priv_data, "tune", "zerolatency", 0);

        // Force IDR on every frame
        av_opt_set(m_codecCtx->priv_data, "x265-params",
                   "keyint=1:min-keyint=1:bframes=0:repeat-headers=1",
                   0);
    }

    // --- Open the encoder ---
    int ret = avcodec_open2(m_codecCtx, m_codec, nullptr);
    if (ret < 0) {
        char errbuf[256];
        av_strerror(ret, errbuf, sizeof(errbuf));
        printf("[FFmpeg] Failed to open encoder '%s': %s\n", name, errbuf);
        destroy();
        return false;
    }

    // --- Allocate frame ---
    m_frame = av_frame_alloc();
    if (!m_frame) {
        printf("[FFmpeg] Failed to allocate frame\n");
        destroy();
        return false;
    }

    if (isVaapiEncoder) {
        // For VA-API: allocate a hardware frame
        m_hwFrame = av_frame_alloc();
        if (!m_hwFrame) {
            printf("[FFmpeg] Failed to allocate HW frame\n");
            destroy();
            return false;
        }

        int ret2 = av_hwframe_get_buffer(m_codecCtx->hw_frames_ctx, m_hwFrame, 0);
        if (ret2 < 0) {
            printf("[FFmpeg] Failed to get HW frame buffer: %d\n", ret2);
            destroy();
            return false;
        }

        // Software frame for upload
        m_frame->format = AV_PIX_FMT_NV12;
        m_frame->width  = width;
        m_frame->height = height;
        av_frame_get_buffer(m_frame, 32);
    } else {
        m_frame->format = m_codecCtx->pix_fmt;
        m_frame->width  = width;
        m_frame->height = height;
        av_frame_get_buffer(m_frame, 32);
    }

    // --- Allocate packet ---
    m_packet = av_packet_alloc();
    if (!m_packet) {
        printf("[FFmpeg] Failed to allocate packet\n");
        destroy();
        return false;
    }

    // --- Setup bitstream filter for Annex-B if needed ---
    // hevc_nvenc and hevc_qsv may output length-prefixed NALUs instead of
    // Annex-B start codes. We apply the hevc_mp4toannexb BSF to ensure
    // consistent output.
    if (isNvencEncoder || isQsvEncoder) {
        const AVBitStreamFilter* bsf = av_bsf_get_by_name("hevc_mp4toannexb");
        if (bsf) {
            int ret2 = av_bsf_alloc(bsf, &m_bsfCtx);
            if (ret2 >= 0) {
                avcodec_parameters_from_context(m_bsfCtx->par_in, m_codecCtx);
                m_bsfCtx->time_base_in = m_codecCtx->time_base;
                av_bsf_init(m_bsfCtx);
            }
        }
    }

    m_encoderName = std::string("FFmpeg (") + name + ")";
    m_initialized = true;
    m_frameIndex  = 0;

    printf("[FFmpeg] Initialized: %dx%d @ %dfps, %d Mbps, HEVC Main, all-intra, encoder=%s\n",
           width, height, fps, bitrateMbps, name);
    return true;
}

// ---------------------------------------------------------------------------
// initialize
// ---------------------------------------------------------------------------
bool FFmpegEncoder::initialize(int width, int height, int fps, int bitrateMbps)
{
    // Try encoders in priority order
    static const char* encoders[] = {
        "hevc_vaapi",   // Intel/AMD hardware via VA-API
        "hevc_nvenc",   // NVIDIA hardware
        "hevc_qsv",     // Intel QuickSync
        "libx265",      // Software fallback
    };

    for (const char* name : encoders) {
        printf("[FFmpeg] Trying encoder: %s\n", name);
        if (tryEncoder(name, width, height, fps, bitrateMbps)) {
            return true;
        }
    }

    return false;
}

// ---------------------------------------------------------------------------
// receivePackets
// ---------------------------------------------------------------------------
bool FFmpegEncoder::receivePackets(uint64_t timestampNs)
{
    bool gotPacket = false;

    while (true) {
        int ret = avcodec_receive_packet(m_codecCtx, m_packet);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            break;
        }
        if (ret < 0) {
            char errbuf[256];
            av_strerror(ret, errbuf, sizeof(errbuf));
            printf("[FFmpeg] receive_packet error: %s\n", errbuf);
            return false;
        }

        const uint8_t* outData = m_packet->data;
        int outSize = m_packet->size;

        // Apply BSF if configured (converts length-prefixed to Annex-B)
        AVPacket* deliverPkt = m_packet;
        AVPacket* bsfPkt = nullptr;

        if (m_bsfCtx) {
            int bsfRet = av_bsf_send_packet(m_bsfCtx, m_packet);
            if (bsfRet >= 0) {
                bsfPkt = av_packet_alloc();
                bsfRet = av_bsf_receive_packet(m_bsfCtx, bsfPkt);
                if (bsfRet >= 0) {
                    deliverPkt = bsfPkt;
                    outData = bsfPkt->data;
                    outSize = bsfPkt->size;
                }
            }
        }

        bool isKeyframe = (deliverPkt->flags & AV_PKT_FLAG_KEY) != 0;

        deliverOutput(outData, static_cast<size_t>(outSize),
                      timestampNs, isKeyframe);

        if (bsfPkt) {
            av_packet_free(&bsfPkt);
        }

        av_packet_unref(m_packet);
        gotPacket = true;
    }

    return gotPacket;
}

// ---------------------------------------------------------------------------
// encode
// ---------------------------------------------------------------------------
bool FFmpegEncoder::encode(const uint8_t* pixelData, int width, int height,
                           int stride, uint64_t timestampNs)
{
    if (!m_initialized || !pixelData) return false;

    // Make frame writable
    av_frame_make_writable(m_frame);

    if (m_isHwEncoder && m_hwFrame) {
        // VA-API path: upload BGRA → NV12 into software frame, then transfer
        bgraToNV12(pixelData, width, height, stride,
                   m_frame->data[0], m_frame->linesize[0],
                   m_frame->data[1], m_frame->linesize[1]);

        // Transfer software frame → hardware surface
        int ret = av_hwframe_transfer_data(m_hwFrame, m_frame, 0);
        if (ret < 0) {
            char errbuf[256];
            av_strerror(ret, errbuf, sizeof(errbuf));
            printf("[FFmpeg] HW frame transfer failed: %s\n", errbuf);
            return false;
        }

        m_hwFrame->pts = m_frameIndex++;
        m_hwFrame->pict_type = AV_PICTURE_TYPE_I; // force IDR

        ret = avcodec_send_frame(m_codecCtx, m_hwFrame);
        if (ret < 0) {
            char errbuf[256];
            av_strerror(ret, errbuf, sizeof(errbuf));
            printf("[FFmpeg] send_frame (HW) failed: %s\n", errbuf);
            return false;
        }

    } else if (m_codecCtx->pix_fmt == AV_PIX_FMT_NV12) {
        // Non-VAAPI hardware encoder expecting NV12
        bgraToNV12(pixelData, width, height, stride,
                   m_frame->data[0], m_frame->linesize[0],
                   m_frame->data[1], m_frame->linesize[1]);

        m_frame->pts = m_frameIndex++;
        m_frame->pict_type = AV_PICTURE_TYPE_I;

        int ret = avcodec_send_frame(m_codecCtx, m_frame);
        if (ret < 0) {
            char errbuf[256];
            av_strerror(ret, errbuf, sizeof(errbuf));
            printf("[FFmpeg] send_frame (NV12) failed: %s\n", errbuf);
            return false;
        }

    } else {
        // Software encoder (YUV420P) — convert BGRA to YUV420P
        // Y plane
        for (int y = 0; y < height; ++y) {
            const uint8_t* row = pixelData + y * stride;
            uint8_t* yRow = m_frame->data[0] + y * m_frame->linesize[0];
            for (int x = 0; x < width; ++x) {
                uint8_t b = row[x * 4 + 0];
                uint8_t g = row[x * 4 + 1];
                uint8_t r = row[x * 4 + 2];
                int yVal = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
                yRow[x] = static_cast<uint8_t>(std::clamp(yVal, 0, 255));
            }
        }

        // U plane (half resolution)
        for (int y = 0; y < height / 2; ++y) {
            const uint8_t* row0 = pixelData + (y * 2) * stride;
            const uint8_t* row1 = pixelData + (y * 2 + 1) * stride;
            uint8_t* uRow = m_frame->data[1] + y * m_frame->linesize[1];
            for (int x = 0; x < width / 2; ++x) {
                int b = 0, g = 0, r = 0;
                for (int dy = 0; dy < 2; ++dy) {
                    const uint8_t* src = (dy == 0) ? row0 : row1;
                    for (int dx = 0; dx < 2; ++dx) {
                        int px = (x * 2 + dx) * 4;
                        b += src[px + 0];
                        g += src[px + 1];
                        r += src[px + 2];
                    }
                }
                b /= 4; g /= 4; r /= 4;
                int u = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
                uRow[x] = static_cast<uint8_t>(std::clamp(u, 0, 255));
            }
        }

        // V plane (half resolution)
        for (int y = 0; y < height / 2; ++y) {
            const uint8_t* row0 = pixelData + (y * 2) * stride;
            const uint8_t* row1 = pixelData + (y * 2 + 1) * stride;
            uint8_t* vRow = m_frame->data[2] + y * m_frame->linesize[2];
            for (int x = 0; x < width / 2; ++x) {
                int b = 0, g = 0, r = 0;
                for (int dy = 0; dy < 2; ++dy) {
                    const uint8_t* src = (dy == 0) ? row0 : row1;
                    for (int dx = 0; dx < 2; ++dx) {
                        int px = (x * 2 + dx) * 4;
                        b += src[px + 0];
                        g += src[px + 1];
                        r += src[px + 2];
                    }
                }
                b /= 4; g /= 4; r /= 4;
                int v = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
                vRow[x] = static_cast<uint8_t>(std::clamp(v, 0, 255));
            }
        }

        m_frame->pts = m_frameIndex++;
        m_frame->pict_type = AV_PICTURE_TYPE_I;

        int ret = avcodec_send_frame(m_codecCtx, m_frame);
        if (ret < 0) {
            char errbuf[256];
            av_strerror(ret, errbuf, sizeof(errbuf));
            printf("[FFmpeg] send_frame (SW) failed: %s\n", errbuf);
            return false;
        }
    }

    return receivePackets(timestampNs);
}

// ---------------------------------------------------------------------------
// updateSettings
// ---------------------------------------------------------------------------
void FFmpegEncoder::updateSettings(int bitrateMbps, float quality, bool gamingBoost)
{
    if (!m_initialized) return;

    // Apply gaming boost overrides
    if (gamingBoost) {
        bitrateMbps = Config::GAMING_BOOST_BITRATE;
        quality     = Config::GAMING_BOOST_QUALITY;
    }

    // Clamp
    bitrateMbps = std::clamp(bitrateMbps,
                             Config::MIN_BITRATE_MBPS,
                             Config::MAX_BITRATE_MBPS);
    m_bitrateMbps = bitrateMbps;

    // Update codec context bitrate (takes effect on next frame)
    m_codecCtx->bit_rate       = static_cast<int64_t>(bitrateMbps) * 1'000'000LL;
    m_codecCtx->rc_max_rate    = static_cast<int64_t>(bitrateMbps) * 1'500'000LL;
    m_codecCtx->rc_buffer_size = static_cast<int>(bitrateMbps) * 1'000'000;

    printf("[FFmpeg] Settings updated: %d Mbps, quality=%.2f, gaming=%d\n",
           bitrateMbps, quality, gamingBoost);
}

// ---------------------------------------------------------------------------
// flush
// ---------------------------------------------------------------------------
void FFmpegEncoder::flush()
{
    if (!m_initialized) return;

    // Send flush signal (NULL frame)
    avcodec_send_frame(m_codecCtx, nullptr);

    // Drain remaining packets
    while (true) {
        int ret = avcodec_receive_packet(m_codecCtx, m_packet);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
        if (ret < 0) break;

        bool isKeyframe = (m_packet->flags & AV_PKT_FLAG_KEY) != 0;
        deliverOutput(m_packet->data, static_cast<size_t>(m_packet->size),
                      0, isKeyframe);
        av_packet_unref(m_packet);
    }
}

// ---------------------------------------------------------------------------
// encoderName
// ---------------------------------------------------------------------------
std::string FFmpegEncoder::encoderName() const {
    return m_encoderName.empty() ? "FFmpeg (unknown)" : m_encoderName;
}

// ---------------------------------------------------------------------------
// destroy
// ---------------------------------------------------------------------------
void FFmpegEncoder::destroy()
{
    if (m_bsfCtx) {
        av_bsf_free(&m_bsfCtx);
        m_bsfCtx = nullptr;
    }

    if (m_packet) {
        av_packet_free(&m_packet);
        m_packet = nullptr;
    }

    if (m_hwFrame) {
        av_frame_free(&m_hwFrame);
        m_hwFrame = nullptr;
    }

    if (m_frame) {
        av_frame_free(&m_frame);
        m_frame = nullptr;
    }

    if (m_codecCtx) {
        avcodec_free_context(&m_codecCtx);
        m_codecCtx = nullptr;
    }

    if (m_hwFramesCtx) {
        av_buffer_unref(&m_hwFramesCtx);
        m_hwFramesCtx = nullptr;
    }

    if (m_hwDeviceCtx) {
        av_buffer_unref(&m_hwDeviceCtx);
        m_hwDeviceCtx = nullptr;
    }

    m_codec       = nullptr;
    m_initialized = false;
    m_isHwEncoder = false;
    m_encoderName.clear();
}

#endif // HAS_FFMPEG
