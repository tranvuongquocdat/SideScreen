#pragma once

#ifdef HAS_VAAPI

#include "VideoEncoder.h"
#include <vector>
#include <cstdint>

#include <va/va.h>
#include <va/va_drm.h>
#include <va/va_enc_hevc.h>

/// Direct VA-API H.265/HEVC encoder.
///
/// Uses libva to talk directly to the GPU's hardware encoder (Intel, AMD).
/// Configuration matches macOS/Windows:
///   - All-intra (every frame IDR)
///   - No B-frames
///   - VBR rate control
///   - HEVC Main profile
///   - Annex-B output with VPS/SPS/PPS on every keyframe
class VaapiEncoder : public VideoEncoder {
public:
    VaapiEncoder();
    ~VaapiEncoder() override;

    /// Attempt to open VA-API encoder on /dev/dri/renderD128.
    /// Returns false if no HEVC encode support is available.
    bool initialize(int width, int height, int fps, int bitrateMbps);

    bool encode(const uint8_t* pixelData, int width, int height,
                int stride, uint64_t timestampNs) override;
    void updateSettings(int bitrateMbps, float quality, bool gamingBoost) override;
    void flush() override;
    std::string encoderName() const override { return "VA-API"; }

private:
    void destroy();

    /// Extract and cache VPS/SPS/PPS NAL units from encoded Annex-B output.
    bool buildParameterSets(const std::vector<uint8_t>& encodedOutput);

    /// Upload BGRA pixels to the VA surface (NV12 conversion).
    bool uploadFrame(const uint8_t* pixelData, int width, int height, int stride);

    /// Execute encode and extract Annex-B bitstream.
    bool executeEncode(uint64_t timestampNs);

    /// Read out encoded bitstream from a coded buffer and deliver to output.
    void readoutBitstream(VABufferID codedBuf, uint64_t timestampNs);

    // DRM file descriptor
    int m_drmFd = -1;

    // VA-API handles
    VADisplay   m_vaDisplay  = nullptr;
    VAConfigID  m_vaConfig   = VA_INVALID_ID;
    VAContextID m_vaContext  = VA_INVALID_ID;

    // Double-buffered surfaces: upload frame N to surface[cur] while
    // GPU encodes frame N-1 from surface[prev], eliminating vaSyncSurface stall.
    static constexpr int kNumBuffers = 2;
    VASurfaceID m_srcSurfaces[kNumBuffers] = { VA_INVALID_SURFACE, VA_INVALID_SURFACE };
    VABufferID  m_codedBufs[kNumBuffers]   = { VA_INVALID_ID, VA_INVALID_ID };
    int         m_curBuf = 0;       // index of surface being uploaded to
    bool        m_prevPending = false; // true if previous frame needs sync+readout
    uint64_t    m_prevTimestampNs = 0; // timestamp of the pending previous frame

    VASurfaceID m_recSurface = VA_INVALID_SURFACE;  // reconstructed (reference)

    // Parameter set NALUs (Annex-B, prepended to every frame)
    std::vector<uint8_t> m_parameterSets;

    // Encode state
    bool     m_initialized = false;
    uint32_t m_frameIndex  = 0;

    // Sequence/picture parameter caches for reconfigure
    VAEncSequenceParameterBufferHEVC m_seqParam = {};
};

#endif // HAS_VAAPI
