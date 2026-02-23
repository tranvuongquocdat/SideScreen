// NvencEncoder.cpp — NVIDIA NVENC H.265 encoder
//
// Dynamically loads nvEncodeAPI64.dll so we never need to link against
// the NVIDIA Video Codec SDK at compile time.  Output is Annex-B H.265
// (0x00000001 start codes), with VPS/SPS/PPS prepended to every IDR frame.
//
// Matching macOS VideoToolbox settings:
//   - All-intra (gopLength=1, every frame is IDR)
//   - No B-frames (frameIntervalP=1)
//   - Ultra-low-latency tuning
//   - Zero frame delay
//   - HEVC Main profile

#include "NvencEncoder.h"
#include "../Config.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <d3d11.h>

#include <cstdio>
#include <cstring>
#include <algorithm>

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static GUID makeGUID(uint32_t d1, uint16_t d2, uint16_t d3, const uint8_t d4[8]) {
    GUID g;
    g.Data1 = d1;
    g.Data2 = d2;
    g.Data3 = d3;
    memcpy(g.Data4, d4, 8);
    return g;
}

static GUID hevcEncodeGUID() {
    const uint8_t d4[] = { 0x94, 0x25, 0xBD, 0xA9, 0x97, 0x5F, 0x76, 0x03 };
    return makeGUID(0x790CDC88, 0x4522, 0x4D7B, d4);
}

static GUID hevcMainProfileGUID() {
    const uint8_t d4[] = { 0x87, 0x8F, 0xF1, 0x25, 0x3B, 0x4D, 0xFD, 0xEC };
    return makeGUID(0xB514C39A, 0xB55B, 0x40FA, d4);
}

static GUID presetP1GUID() {
    // P1 = fastest / lowest latency
    const uint8_t d4[] = { 0x98, 0x01, 0xF0, 0x48, 0x99, 0x3A, 0xE2, 0xDB };
    return makeGUID(0xFC0A8D3E, 0xE7B3, 0x44B8, d4);
}

static GUID presetP4GUID() {
    // P4 = balanced quality / speed
    const uint8_t d4[] = { 0xB5, 0x52, 0x0A, 0x88, 0x4E, 0x1D, 0x27, 0xD8 };
    return makeGUID(0xB2FC312F, 0x297A, 0x4A04, d4);
}

// ---------------------------------------------------------------------------
// Ctor / Dtor
// ---------------------------------------------------------------------------
NvencEncoder::NvencEncoder() = default;

NvencEncoder::~NvencEncoder() {
    destroy();
}

// ---------------------------------------------------------------------------
// initialize
// ---------------------------------------------------------------------------
bool NvencEncoder::initialize(ID3D11Device* device, int width, int height,
                              int fps, int bitrateMbps)
{
    if (m_initialized) destroy();

    m_device     = device;
    m_width      = width;
    m_height     = height;
    m_fps        = fps;
    m_bitrateMbps = bitrateMbps;

    // --- 1. Load DLL ---
    m_nvencLib = LoadLibraryW(L"nvEncodeAPI64.dll");
    if (!m_nvencLib) {
        // Try 32-bit name as fallback (unlikely on 64-bit build)
        m_nvencLib = LoadLibraryW(L"nvEncodeAPI.dll");
    }
    if (!m_nvencLib) {
        printf("[NVENC] nvEncodeAPI64.dll not found\n");
        return false;
    }

    // --- 2. Resolve NvEncodeAPICreateInstance ---
    auto createInstance = reinterpret_cast<NvEncodeAPICreateInstance_t>(
        GetProcAddress(m_nvencLib, "NvEncodeAPICreateInstance"));
    if (!createInstance) {
        printf("[NVENC] NvEncodeAPICreateInstance not found in DLL\n");
        FreeLibrary(m_nvencLib);
        m_nvencLib = nullptr;
        return false;
    }

    memset(&m_nvenc, 0, sizeof(m_nvenc));
    m_nvenc.version = NV_ENCODE_API_FUNCTION_LIST_VER;
    NV_ENC_STATUS st = createInstance(&m_nvenc);
    if (st != NV_ENC_SUCCESS) {
        printf("[NVENC] NvEncodeAPICreateInstance failed: %d\n", st);
        FreeLibrary(m_nvencLib);
        m_nvencLib = nullptr;
        return false;
    }

    // --- 3. Open encode session with D3D11 device ---
    NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS sessionParams = {};
    sessionParams.version    = NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER;
    sessionParams.deviceType = NV_ENC_DEVICE_TYPE_DIRECTX;
    sessionParams.device     = device;
    sessionParams.apiVersion = NVENCAPI_VERSION;

    st = m_nvenc.nvEncOpenEncodeSessionEx(&sessionParams, &m_encoder);
    if (st != NV_ENC_SUCCESS) {
        printf("[NVENC] OpenEncodeSessionEx failed: %d\n", st);
        destroy();
        return false;
    }

    // --- 4. Get preset config as starting point ---
    GUID codecGUID  = hevcEncodeGUID();
    GUID presetGUID = presetP1GUID(); // fastest for ultra-low-latency

    NV_ENC_PRESET_CONFIG presetConfig = {};
    presetConfig.version = NV_ENC_PRESET_CONFIG_VER;
    presetConfig.presetCfg.version = NV_ENC_CONFIG_VER;

    st = m_nvenc.nvEncGetEncodePresetConfigEx(
        m_encoder, codecGUID, presetGUID,
        NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY, &presetConfig);
    if (st != NV_ENC_SUCCESS) {
        printf("[NVENC] GetEncodePresetConfigEx failed: %d\n", st);
        destroy();
        return false;
    }

    // --- 5. Configure encode parameters ---
    m_encodeConfig = presetConfig.presetCfg;

    // Profile: Main
    m_encodeConfig.profileGUID = hevcMainProfileGUID();

    // All-intra: every frame is IDR (matches macOS MaxKeyFrameInterval=1)
    m_encodeConfig.gopLength       = 1;
    m_encodeConfig.frameIntervalP  = 1; // no B-frames (1 = I only when gop=1)

    // Rate control: VBR for better burst capacity (matches macOS approach)
    m_encodeConfig.rcParams.rateControlMode = NV_ENC_PARAMS_RC_VBR;
    m_encodeConfig.rcParams.averageBitRate  = static_cast<uint32_t>(bitrateMbps) * 1'000'000u;
    m_encodeConfig.rcParams.maxBitRate      = static_cast<uint32_t>(bitrateMbps) * 1'500'000u;
    m_encodeConfig.rcParams.vbvBufferSize   = static_cast<uint32_t>(bitrateMbps) * 1'000'000u; // 1 second
    m_encodeConfig.rcParams.vbvInitialDelay = m_encodeConfig.rcParams.vbvBufferSize;

    // Initialize params
    memset(&m_initParams, 0, sizeof(m_initParams));
    m_initParams.version       = NV_ENC_INITIALIZE_PARAMS_VER;
    m_initParams.encodeGUID    = codecGUID;
    m_initParams.presetGUID    = presetGUID;
    m_initParams.encodeWidth   = static_cast<uint32_t>(width);
    m_initParams.encodeHeight  = static_cast<uint32_t>(height);
    m_initParams.darWidth      = static_cast<uint32_t>(width);
    m_initParams.darHeight     = static_cast<uint32_t>(height);
    m_initParams.frameRateNum  = static_cast<uint32_t>(fps);
    m_initParams.frameRateDen  = 1;
    m_initParams.enableEncodeAsync = 0; // synchronous — simpler, zero-delay
    m_initParams.enablePTD     = 1;     // picture type decision by encoder
    m_initParams.encodeConfig  = &m_encodeConfig;
    m_initParams.tuningInfo    = NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY;

    st = m_nvenc.nvEncInitializeEncoder(m_encoder, &m_initParams);
    if (st != NV_ENC_SUCCESS) {
        printf("[NVENC] InitializeEncoder failed: %d\n", st);
        destroy();
        return false;
    }

    // --- 6. Create staging texture (BGRA, same size) ---
    {
        D3D11_TEXTURE2D_DESC desc = {};
        desc.Width            = static_cast<UINT>(width);
        desc.Height           = static_cast<UINT>(height);
        desc.MipLevels        = 1;
        desc.ArraySize        = 1;
        desc.Format           = DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.Usage            = D3D11_USAGE_DEFAULT;
        desc.BindFlags        = 0;
        desc.MiscFlags        = 0;

        HRESULT hr = device->CreateTexture2D(&desc, nullptr, &m_stagingTexture);
        if (FAILED(hr)) {
            printf("[NVENC] CreateTexture2D staging failed: 0x%lx\n", hr);
            destroy();
            return false;
        }
    }

    // --- 7. Register the staging texture with NVENC ---
    {
        NV_ENC_REGISTER_RESOURCE regRes = {};
        regRes.version            = NV_ENC_REGISTER_RESOURCE_VER;
        regRes.resourceType       = NV_ENC_INPUT_RESOURCE_TYPE_DIRECTX;
        regRes.resourceToRegister = m_stagingTexture;
        regRes.width              = static_cast<uint32_t>(width);
        regRes.height             = static_cast<uint32_t>(height);
        regRes.bufferFormat       = NV_ENC_BUFFER_FORMAT_ARGB;
        regRes.bufferUsage        = 0; // input

        st = m_nvenc.nvEncRegisterResource(m_encoder, &regRes);
        if (st != NV_ENC_SUCCESS) {
            printf("[NVENC] RegisterResource failed: %d\n", st);
            destroy();
            return false;
        }
        m_registeredResource = regRes.registeredResource;
    }

    // --- 8. Create output bitstream buffer ---
    {
        NV_ENC_CREATE_BITSTREAM_BUFFER bsBuf = {};
        bsBuf.version = NV_ENC_CREATE_BITSTREAM_BUFFER_VER;

        st = m_nvenc.nvEncCreateBitstreamBuffer(m_encoder, &bsBuf);
        if (st != NV_ENC_SUCCESS) {
            printf("[NVENC] CreateBitstreamBuffer failed: %d\n", st);
            destroy();
            return false;
        }
        m_bitstreamBuffer = bsBuf.bitstreamBuffer;
    }

    m_initialized = true;
    m_frameIndex  = 0;
    printf("[NVENC] Initialized: %dx%d @ %dfps, %d Mbps, HEVC Main, all-intra\n",
           width, height, fps, bitrateMbps);
    return true;
}

// ---------------------------------------------------------------------------
// encode
// ---------------------------------------------------------------------------
bool NvencEncoder::encode(ID3D11Texture2D* inputTexture, uint64_t timestampNs)
{
    if (!m_initialized || !inputTexture) return false;

    // Copy caller's texture into our staging texture (avoids lifetime issues)
    ID3D11DeviceContext* ctx = nullptr;
    m_device->GetImmediateContext(&ctx);
    if (!ctx) return false;
    ctx->CopyResource(m_stagingTexture, inputTexture);
    ctx->Release();

    // Map the registered resource
    NV_ENC_MAP_INPUT_RESOURCE mapRes = {};
    mapRes.version            = NV_ENC_MAP_INPUT_RESOURCE_VER;
    mapRes.registeredResource = m_registeredResource;

    NV_ENC_STATUS st = m_nvenc.nvEncMapInputResource(m_encoder, &mapRes);
    if (st != NV_ENC_SUCCESS) {
        printf("[NVENC] MapInputResource failed: %d\n", st);
        return false;
    }

    // Encode
    NV_ENC_PIC_PARAMS picParams = {};
    picParams.version        = NV_ENC_PIC_PARAMS_VER;
    picParams.inputWidth     = static_cast<uint32_t>(m_width);
    picParams.inputHeight    = static_cast<uint32_t>(m_height);
    picParams.inputPitch     = 0; // determined by registered resource
    picParams.encodePicFlags = NV_ENC_PIC_FLAG_FORCEIDR | NV_ENC_PIC_FLAG_OUTPUT_SPSPPS;
    picParams.frameIdx       = m_frameIndex++;
    picParams.inputTimeStamp = timestampNs;
    picParams.inputBuffer    = mapRes.mappedResource;
    picParams.outputBitstream = m_bitstreamBuffer;
    picParams.bufferFmt      = mapRes.mappedBufferFmt;
    picParams.pictureStruct  = NV_ENC_PIC_STRUCT_FRAME;

    st = m_nvenc.nvEncEncodePicture(m_encoder, &picParams);

    // Unmap regardless of encode result
    m_nvenc.nvEncUnmapInputResource(m_encoder, mapRes.mappedResource);

    if (st != NV_ENC_SUCCESS) {
        printf("[NVENC] EncodePicture failed: %d\n", st);
        return false;
    }

    // Lock and read bitstream
    NV_ENC_LOCK_BITSTREAM lockBS = {};
    lockBS.version         = NV_ENC_LOCK_BITSTREAM_VER;
    lockBS.outputBitstream = m_bitstreamBuffer;

    st = m_nvenc.nvEncLockBitstream(m_encoder, &lockBS);
    if (st != NV_ENC_SUCCESS) {
        printf("[NVENC] LockBitstream failed: %d\n", st);
        return false;
    }

    // NVENC with FORCEIDR + OUTPUT_SPSPPS produces Annex-B bitstream with
    // 0x00000001 start codes, including VPS/SPS/PPS before the IDR slice.
    // Since we force every frame to be IDR with OUTPUT_SPSPPS, every frame
    // includes the parameter sets.
    bool isKeyframe = (lockBS.pictureType == NV_ENC_PIC_TYPE_IDR);

    deliverOutput(
        static_cast<const uint8_t*>(lockBS.bitstreamBufferPtr),
        lockBS.bitstreamSizeInBytes,
        timestampNs,
        isKeyframe
    );

    m_nvenc.nvEncUnlockBitstream(m_encoder, m_bitstreamBuffer);
    return true;
}

// ---------------------------------------------------------------------------
// updateSettings
// ---------------------------------------------------------------------------
void NvencEncoder::updateSettings(int bitrateMbps, float quality, bool gamingBoost)
{
    if (!m_initialized) return;

    // Apply gaming boost overrides
    if (gamingBoost) {
        bitrateMbps = Config::GAMING_BOOST_BITRATE;
        quality     = Config::GAMING_BOOST_QUALITY;
    }

    // Clamp
    bitrateMbps = std::clamp(bitrateMbps, Config::MIN_BITRATE_MBPS, Config::MAX_BITRATE_MBPS);
    m_bitrateMbps = bitrateMbps;

    // Update rate control
    m_encodeConfig.rcParams.averageBitRate = static_cast<uint32_t>(bitrateMbps) * 1'000'000u;
    m_encodeConfig.rcParams.maxBitRate     = static_cast<uint32_t>(bitrateMbps) * 1'500'000u;
    m_encodeConfig.rcParams.vbvBufferSize  = static_cast<uint32_t>(bitrateMbps) * 1'000'000u;
    m_encodeConfig.rcParams.vbvInitialDelay = m_encodeConfig.rcParams.vbvBufferSize;

    // Reconfigure the encoder without destroying the session
    NV_ENC_RECONFIGURE_PARAMS reconf = {};
    reconf.version           = NV_ENC_RECONFIGURE_PARAMS_VER;
    reconf.reInitEncodeParams = m_initParams;
    reconf.resetEncoder      = 1;
    reconf.forceIDR          = 1;

    NV_ENC_STATUS st = m_nvenc.nvEncReconfigureEncoder(m_encoder, &reconf);
    if (st != NV_ENC_SUCCESS) {
        printf("[NVENC] ReconfigureEncoder failed: %d (non-fatal)\n", st);
    } else {
        printf("[NVENC] Reconfigured: %d Mbps, quality=%.2f, gaming=%d\n",
               bitrateMbps, quality, gamingBoost);
    }
}

// ---------------------------------------------------------------------------
// flush
// ---------------------------------------------------------------------------
void NvencEncoder::flush()
{
    if (!m_initialized) return;

    // Send EOS to flush pending frames
    NV_ENC_PIC_PARAMS picParams = {};
    picParams.version        = NV_ENC_PIC_PARAMS_VER;
    picParams.encodePicFlags = NV_ENC_PIC_FLAG_EOS;

    m_nvenc.nvEncEncodePicture(m_encoder, &picParams);
}

// ---------------------------------------------------------------------------
// destroy
// ---------------------------------------------------------------------------
void NvencEncoder::destroy()
{
    if (m_encoder) {
        if (m_bitstreamBuffer) {
            m_nvenc.nvEncDestroyBitstreamBuffer(m_encoder, m_bitstreamBuffer);
            m_bitstreamBuffer = nullptr;
        }
        if (m_registeredResource) {
            m_nvenc.nvEncUnregisterResource(m_encoder, m_registeredResource);
            m_registeredResource = nullptr;
        }
        m_nvenc.nvEncDestroyEncoder(m_encoder);
        m_encoder = nullptr;
    }

    if (m_stagingTexture) {
        m_stagingTexture->Release();
        m_stagingTexture = nullptr;
    }

    if (m_nvencLib) {
        FreeLibrary(m_nvencLib);
        m_nvencLib = nullptr;
    }

    m_initialized = false;
}
