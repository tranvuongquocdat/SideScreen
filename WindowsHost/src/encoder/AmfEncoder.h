#pragma once

#include "VideoEncoder.h"
#include <vector>
#include <cstdint>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

// Forward-declare AMF types so we don't require the SDK headers at compile time.
// At runtime we load amfrt64.dll and resolve everything dynamically.
namespace amf {
    class AMFContext;
    class AMFComponent;
    class AMFSurface;
    class AMFBuffer;
    class AMFData;
    class AMFFactory;
    class AMFTrace;
}

/// AMD AMF H.265 encoder.
/// Dynamically loads amfrt64.dll at runtime.
class AmfEncoder : public VideoEncoder {
public:
    AmfEncoder();
    ~AmfEncoder() override;

    bool initialize(ID3D11Device* device, int width, int height,
                    int fps, int bitrateMbps);

    bool encode(ID3D11Texture2D* inputTexture, uint64_t timestampNs) override;
    void updateSettings(int bitrateMbps, float quality, bool gamingBoost) override;
    void flush() override;
    std::string encoderName() const override { return "AMF"; }

private:
    void destroy();

    /// Convert AMF AVCC/HVCC output to Annex-B if necessary.
    /// AMF can output in either format depending on configuration.
    void ensureAnnexB(const uint8_t* input, size_t inputSize,
                      std::vector<uint8_t>& output);

    // DLL handle
    HMODULE m_amfLib = nullptr;

    // AMF objects (stored as void* to avoid needing AMF headers)
    void* m_factory   = nullptr;  // AMFFactory*
    void* m_context   = nullptr;  // AMFContext*
    void* m_encoder   = nullptr;  // AMFComponent*

    // D3D11 device (not owned)
    ID3D11Device* m_device = nullptr;

    // Staging texture (owned)
    ID3D11Texture2D* m_stagingTexture = nullptr;

    // Scratch buffer for Annex-B conversion
    std::vector<uint8_t> m_annexBBuffer;

    bool m_initialized = false;
    uint32_t m_frameIndex = 0;

    // -----------------------------------------------------------------------
    // AMF function pointer types (loaded at runtime)
    // -----------------------------------------------------------------------
    using AMFInit_Fn       = long(__cdecl*)(uint64_t version, void** ppFactory);
    using AMFQueryVersion_Fn = long(__cdecl*)(uint64_t* pVersion);

    AMFInit_Fn       m_amfInit       = nullptr;
    AMFQueryVersion_Fn m_amfQueryVer = nullptr;

    // We store the AMF version for API calls
    uint64_t m_amfVersion = 0;
};
