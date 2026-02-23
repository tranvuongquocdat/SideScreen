// VideoEncoder.cpp — Factory: try VaapiEncoder → FFmpegEncoder → nullptr
//
// Conditional compilation:
//   HAS_VAAPI  — defined by CMake when libva + libva-drm are found
//   HAS_FFMPEG — defined by CMake when libavcodec + libavutil are found

#include "VideoEncoder.h"
#include "../Config.h"

#ifdef HAS_VAAPI
#include "VaapiEncoder.h"
#endif

#ifdef HAS_FFMPEG
#include "FFmpegEncoder.h"
#endif

#include <cstdio>
#include <algorithm>

std::unique_ptr<VideoEncoder> VideoEncoder::create(
    int width, int height, int fps, int bitrateMbps)
{
    // Clamp bitrate to configured range
    bitrateMbps = std::clamp(bitrateMbps,
                             Config::MIN_BITRATE_MBPS,
                             Config::MAX_BITRATE_MBPS);

    // --- Try VA-API direct (lowest overhead, Intel/AMD) ---
#ifdef HAS_VAAPI
    {
        auto enc = std::make_unique<VaapiEncoder>();
        if (enc->initialize(width, height, fps, bitrateMbps)) {
            printf("[VideoEncoder] Using VA-API direct encoder\n");
            return enc;
        }
        printf("[VideoEncoder] VA-API not available, trying next...\n");
    }
#else
    printf("[VideoEncoder] VA-API support not compiled in, trying next...\n");
#endif

    // --- Try FFmpeg (hevc_vaapi → hevc_nvenc → hevc_qsv → libx265) ---
#ifdef HAS_FFMPEG
    {
        auto enc = std::make_unique<FFmpegEncoder>();
        if (enc->initialize(width, height, fps, bitrateMbps)) {
            printf("[VideoEncoder] Using FFmpeg encoder: %s\n",
                   enc->encoderName().c_str());
            return enc;
        }
        printf("[VideoEncoder] FFmpeg encoder not available\n");
    }
#else
    printf("[VideoEncoder] FFmpeg support not compiled in\n");
#endif

    printf("[VideoEncoder] ERROR: No H.265 encoder available!\n");
    return nullptr;
}
