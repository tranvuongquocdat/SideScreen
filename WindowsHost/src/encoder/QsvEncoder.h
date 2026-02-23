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
struct IMFDXGIDeviceManager;

/// Intel QuickSync H.265 encoder via Media Foundation Transform (MFT).
///
/// MF provides a hardware-agnostic path to Intel QSV (and potentially other
/// hardware encoders registered as MFTs). We specifically request hardware
/// HEVC encoding; if no QSV-capable GPU is present, initialization fails
/// and the factory moves on to the next backend.
///
/// Output: Annex-B H.265 with 0x00000001 start codes.
class QsvEncoder : public VideoEncoder {
public:
    QsvEncoder();
    ~QsvEncoder() override;

    bool initialize(ID3D11Device* device, int width, int height,
                    int fps, int bitrateMbps);

    bool encode(ID3D11Texture2D* inputTexture, uint64_t timestampNs) override;
    void updateSettings(int bitrateMbps, float quality, bool gamingBoost) override;
    void flush() override;
    std::string encoderName() const override { return "QuickSync"; }

private:
    void destroy();

    /// Convert MFT output (may be length-prefixed) to Annex-B.
    void convertToAnnexB(const uint8_t* input, size_t inputSize,
                         std::vector<uint8_t>& output);

    // D3D11 (not owned)
    ID3D11Device* m_device = nullptr;

    // Media Foundation objects
    IMFTransform*          m_transform  = nullptr;
    IMFDXGIDeviceManager*  m_dxgiMgr    = nullptr;
    HANDLE                 m_deviceHandle = nullptr;

    // Staging texture (owned)
    ID3D11Texture2D* m_stagingTexture = nullptr;

    // Scratch buffer
    std::vector<uint8_t> m_annexBBuffer;

    bool m_initialized = false;
    bool m_mfStarted   = false;  // MF COM initialized
    uint32_t m_frameIndex = 0;

    // NAL length size from MFT output (typically 4)
    int m_nalLengthSize = 4;

    // Stream IDs
    DWORD m_inputStreamID  = 0;
    DWORD m_outputStreamID = 0;
};
