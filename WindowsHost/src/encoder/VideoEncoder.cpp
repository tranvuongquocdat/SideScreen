#include "VideoEncoder.h"
#include "NvencEncoder.h"
#include "AmfEncoder.h"
#include "QsvEncoder.h"
#include "../Config.h"

#include <cstdio>

std::unique_ptr<VideoEncoder> VideoEncoder::create(
    ID3D11Device* device, int width, int height, int fps, int bitrateMbps)
{
    // Clamp bitrate to configured range
    if (bitrateMbps < Config::MIN_BITRATE_MBPS) bitrateMbps = Config::MIN_BITRATE_MBPS;
    if (bitrateMbps > Config::MAX_BITRATE_MBPS) bitrateMbps = Config::MAX_BITRATE_MBPS;

    // --- Try NVENC (NVIDIA) ---
    {
        auto enc = std::make_unique<NvencEncoder>();
        if (enc->initialize(device, width, height, fps, bitrateMbps)) {
            printf("[VideoEncoder] Using NVENC (NVIDIA) encoder\n");
            return enc;
        }
        printf("[VideoEncoder] NVENC not available, trying next...\n");
    }

    // --- Try AMF (AMD) ---
    {
        auto enc = std::make_unique<AmfEncoder>();
        if (enc->initialize(device, width, height, fps, bitrateMbps)) {
            printf("[VideoEncoder] Using AMF (AMD) encoder\n");
            return enc;
        }
        printf("[VideoEncoder] AMF not available, trying next...\n");
    }

    // --- Try QuickSync (Intel) ---
    {
        auto enc = std::make_unique<QsvEncoder>();
        if (enc->initialize(device, width, height, fps, bitrateMbps)) {
            printf("[VideoEncoder] Using QuickSync (Intel) encoder\n");
            return enc;
        }
        printf("[VideoEncoder] QuickSync not available\n");
    }

    printf("[VideoEncoder] ERROR: No hardware H.265 encoder available!\n");
    return nullptr;
}
