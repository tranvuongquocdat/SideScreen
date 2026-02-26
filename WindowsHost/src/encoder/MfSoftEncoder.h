#pragma once

#include "VideoEncoder.h"
#include <vector>
#include <cstdint>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

// Forward-declare MF types (full headers included in .cpp)
struct IMFTransform;
struct IMFMediaType;
struct IMFSample;
struct IMFMediaBuffer;

/// Software H.265 encoder via Windows Media Foundation.
///
/// Uses MFT (Media Foundation Transform) to encode via the Microsoft HEVC
/// software encoder (Microsoft.HEVC.Encoder) that ships with Windows 10+.
/// This is a CPU-only fallback when no GPU encoder (NVENC/AMF/QSV) is
/// available. Performance is limited but ensures the app always works.
///
/// Output: Annex-B H.265 with 0x00000001 start codes.
class MfSoftEncoder : public VideoEncoder {
public:
    MfSoftEncoder();
    ~MfSoftEncoder() override;

    bool initialize(ID3D11Device* device, int width, int height,
                    int fps, int bitrateMbps);

    bool encode(ID3D11Texture2D* inputTexture, uint64_t timestampNs) override;
    void updateSettings(int bitrateMbps, float quality, bool gamingBoost) override;
    void flush() override;
    std::string encoderName() const override { return "MF-Software"; }

private:
    void destroy();

    /// Convert MFT output (may be length-prefixed) to Annex-B.
    void convertToAnnexB(const uint8_t* input, size_t inputSize,
                         std::vector<uint8_t>& output);

    // D3D11 (not owned)
    ID3D11Device* m_device = nullptr;

    // Media Foundation objects
    IMFTransform* m_transform = nullptr;

    // Staging texture (owned) — CPU-readable copy for software encoder
    ID3D11Texture2D* m_stagingTexture = nullptr;

    // Scratch buffer
    std::vector<uint8_t> m_annexBBuffer;

    bool m_initialized = false;
    bool m_mfStarted   = false;
    uint32_t m_frameIndex = 0;

    int m_nalLengthSize = 4;

    DWORD m_inputStreamID  = 0;
    DWORD m_outputStreamID = 0;
};
