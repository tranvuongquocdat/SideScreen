// QsvEncoder.cpp — Intel QuickSync H.265 encoder via Media Foundation
//
// Uses MFT (Media Foundation Transform) to access Intel QSV hardware encoding.
// This is the standard Windows API path to Intel's hardware encoder.
//
// Output: Annex-B H.265 with 0x00000001 start codes.
// Settings: all-intra, no B-frames, low-latency, HEVC Main profile.

#include "QsvEncoder.h"
#include "../Config.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>

// Media Foundation headers
#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>
#include <mferror.h>
#include <mfreadwrite.h>
#include <codecapi.h>
#include <initguid.h>

#include <cstdio>
#include <cstring>
#include <algorithm>

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "mf.lib")

// HEVC encoder MFT CLSID (Intel QSV / hardware)
// {47F11CF7-357B-4168-9E61-2F1D6BCD8F16}
DEFINE_GUID(MFVideoFormat_HEVC,
    0x43564548, 0x0000, 0x0010, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71);

// Low-latency attribute
DEFINE_GUID(MF_LOW_LATENCY,
    0x9C27891A, 0xED7A, 0x40e1, 0x88, 0xE8, 0xB2, 0x27, 0x27, 0xA0, 0x24, 0xEE);

// Hardware acceleration attribute
DEFINE_GUID(MF_TRANSFORM_FLAGS_Attribute,
    0x9359BB7E, 0x6275, 0x46C4, 0xA0, 0x25, 0x1C, 0x01, 0xE4, 0x5F, 0x1A, 0x86);

// D3D11 aware attribute
DEFINE_GUID(MF_SA_D3D11_AWARE,
    0x206B4FC8, 0xFCF9, 0x4C51, 0xAF, 0xE3, 0x97, 0x64, 0x36, 0x9E, 0x33, 0xA0);

// DXGI device manager for MFT
DEFINE_GUID(MF_SA_D3D_MANAGER_TOKEN,
    0xC294C3A3, 0xE80D, 0x4893, 0xA0, 0x1D, 0xDE, 0x10, 0x8D, 0xBA, 0xCC, 0x3C);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
template<typename T>
static void safeRelease(T*& p) {
    if (p) { p->Release(); p = nullptr; }
}

QsvEncoder::QsvEncoder() = default;

QsvEncoder::~QsvEncoder() {
    destroy();
}

// ---------------------------------------------------------------------------
// initialize
// ---------------------------------------------------------------------------
bool QsvEncoder::initialize(ID3D11Device* device, int width, int height,
                            int fps, int bitrateMbps)
{
    if (m_initialized) destroy();

    m_device      = device;
    m_width       = width;
    m_height      = height;
    m_fps         = fps;
    m_bitrateMbps = bitrateMbps;

    // --- 1. Initialize Media Foundation ---
    HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET);
    if (FAILED(hr)) {
        printf("[QSV] MFStartup failed: 0x%lx\n", hr);
        return false;
    }
    m_mfStarted = true;

    // --- 2. Create DXGI device manager for hardware MFT ---
    UINT resetToken = 0;
    hr = MFCreateDXGIDeviceManager(&resetToken, &m_dxgiMgr);
    if (FAILED(hr)) {
        printf("[QSV] MFCreateDXGIDeviceManager failed: 0x%lx\n", hr);
        destroy();
        return false;
    }

    // Associate our D3D11 device with the DXGI manager
    ID3D10Multithread* mt = nullptr;
    device->QueryInterface(__uuidof(ID3D10Multithread), reinterpret_cast<void**>(&mt));
    if (mt) {
        mt->SetMultithreadProtected(TRUE);
        mt->Release();
    }

    hr = m_dxgiMgr->ResetDevice(device, resetToken);
    if (FAILED(hr)) {
        printf("[QSV] ResetDevice failed: 0x%lx\n", hr);
        destroy();
        return false;
    }

    // --- 3. Find hardware HEVC encoder MFT ---
    MFT_REGISTER_TYPE_INFO outputType = {};
    outputType.guidMajorType = MFMediaType_Video;
    outputType.guidSubtype   = MFVideoFormat_HEVC;

    IMFActivate** ppActivate = nullptr;
    UINT32 activateCount = 0;

    hr = MFTEnumEx(
        MFT_CATEGORY_VIDEO_ENCODER,
        MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
        nullptr,       // input type: any
        &outputType,   // output type: HEVC
        &ppActivate,
        &activateCount
    );

    if (FAILED(hr) || activateCount == 0) {
        printf("[QSV] No hardware HEVC encoder MFT found\n");
        if (ppActivate) CoTaskMemFree(ppActivate);
        destroy();
        return false;
    }

    // Activate the first hardware encoder
    hr = ppActivate[0]->ActivateObject(IID_IMFTransform,
                                       reinterpret_cast<void**>(&m_transform));

    // Release all activate objects
    for (UINT32 i = 0; i < activateCount; i++) {
        ppActivate[i]->Release();
    }
    CoTaskMemFree(ppActivate);

    if (FAILED(hr) || !m_transform) {
        printf("[QSV] ActivateObject failed: 0x%lx\n", hr);
        destroy();
        return false;
    }

    // --- 4. Set D3D11 device manager on the MFT ---
    hr = m_transform->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER,
                                     reinterpret_cast<ULONG_PTR>(m_dxgiMgr));
    if (FAILED(hr)) {
        printf("[QSV] SetD3DManager failed: 0x%lx (may work without HW accel)\n", hr);
        // Continue anyway — some MFTs work without D3D manager
    }

    // Get stream IDs
    hr = m_transform->GetStreamIDs(1, &m_inputStreamID, 1, &m_outputStreamID);
    if (hr == E_NOTIMPL) {
        // MFT uses default stream IDs (0)
        m_inputStreamID = 0;
        m_outputStreamID = 0;
    }

    // --- 5. Configure output media type (HEVC) ---
    {
        IMFMediaType* outputMediaType = nullptr;
        hr = MFCreateMediaType(&outputMediaType);
        if (FAILED(hr)) { destroy(); return false; }

        outputMediaType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        outputMediaType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_HEVC);
        outputMediaType->SetUINT32(MF_MT_AVG_BITRATE,
                                   static_cast<UINT32>(bitrateMbps) * 1'000'000u);
        MFSetAttributeSize(outputMediaType, MF_MT_FRAME_SIZE, width, height);
        MFSetAttributeRatio(outputMediaType, MF_MT_FRAME_RATE, fps, 1);
        outputMediaType->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        outputMediaType->SetUINT32(MF_MT_MPEG2_PROFILE, 1); // Main profile

        hr = m_transform->SetOutputType(m_outputStreamID, outputMediaType, 0);
        safeRelease(outputMediaType);
        if (FAILED(hr)) {
            printf("[QSV] SetOutputType failed: 0x%lx\n", hr);
            destroy();
            return false;
        }
    }

    // --- 6. Configure input media type (NV12 or BGRA) ---
    {
        IMFMediaType* inputMediaType = nullptr;
        hr = MFCreateMediaType(&inputMediaType);
        if (FAILED(hr)) { destroy(); return false; }

        inputMediaType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        // Try NV12 first (preferred for hardware encoders)
        inputMediaType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
        MFSetAttributeSize(inputMediaType, MF_MT_FRAME_SIZE, width, height);
        MFSetAttributeRatio(inputMediaType, MF_MT_FRAME_RATE, fps, 1);
        inputMediaType->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);

        hr = m_transform->SetInputType(m_inputStreamID, inputMediaType, 0);
        if (FAILED(hr)) {
            // Fallback to BGRA
            inputMediaType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_ARGB32);
            hr = m_transform->SetInputType(m_inputStreamID, inputMediaType, 0);
        }
        safeRelease(inputMediaType);
        if (FAILED(hr)) {
            printf("[QSV] SetInputType failed: 0x%lx\n", hr);
            destroy();
            return false;
        }
    }

    // --- 7. Configure encoder-specific settings via ICodecAPI ---
    {
        ICodecAPI* codecAPI = nullptr;
        hr = m_transform->QueryInterface(IID_ICodecAPI,
                                         reinterpret_cast<void**>(&codecAPI));
        if (SUCCEEDED(hr) && codecAPI) {
            VARIANT var;

            // Low latency mode
            VariantInit(&var);
            var.vt = VT_BOOL;
            var.boolVal = VARIANT_TRUE;
            codecAPI->SetValue(&CODECAPI_AVEncCommonLowLatency, &var);

            // GOP size = 1 (all-intra)
            VariantInit(&var);
            var.vt = VT_UI4;
            var.ulVal = 1;
            codecAPI->SetValue(&CODECAPI_AVEncMPVGOPSize, &var);

            // Max B-frames = 0
            VariantInit(&var);
            var.vt = VT_UI4;
            var.ulVal = 0;
            codecAPI->SetValue(&CODECAPI_AVEncMPVDefaultBPictureCount, &var);

            // Rate control: VBR
            VariantInit(&var);
            var.vt = VT_UI4;
            var.ulVal = eAVEncCommonRateControlMode_UnconstrainedVBR;
            codecAPI->SetValue(&CODECAPI_AVEncCommonRateControlMode, &var);

            // Mean bitrate
            VariantInit(&var);
            var.vt = VT_UI4;
            var.ulVal = static_cast<ULONG>(bitrateMbps) * 1'000'000u;
            codecAPI->SetValue(&CODECAPI_AVEncCommonMeanBitRate, &var);

            // Max bitrate
            VariantInit(&var);
            var.vt = VT_UI4;
            var.ulVal = static_cast<ULONG>(bitrateMbps) * 1'500'000u;
            codecAPI->SetValue(&CODECAPI_AVEncCommonMaxBitRate, &var);

            codecAPI->Release();
        }
    }

    // --- 8. Set low-latency attribute directly on the transform ---
    {
        IMFAttributes* attrs = nullptr;
        hr = m_transform->GetAttributes(&attrs);
        if (SUCCEEDED(hr) && attrs) {
            attrs->SetUINT32(MF_LOW_LATENCY, TRUE);
            attrs->Release();
        }
    }

    // --- 9. Start streaming ---
    hr = m_transform->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    if (FAILED(hr)) {
        printf("[QSV] BEGIN_STREAMING failed: 0x%lx\n", hr);
        // Non-fatal, continue
    }

    hr = m_transform->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    if (FAILED(hr)) {
        printf("[QSV] START_OF_STREAM failed: 0x%lx\n", hr);
    }

    // --- 10. Create staging texture ---
    {
        D3D11_TEXTURE2D_DESC desc = {};
        desc.Width            = static_cast<UINT>(width);
        desc.Height           = static_cast<UINT>(height);
        desc.MipLevels        = 1;
        desc.ArraySize        = 1;
        desc.Format           = DXGI_FORMAT_NV12; // Match input type
        desc.SampleDesc.Count = 1;
        desc.Usage            = D3D11_USAGE_DEFAULT;
        desc.BindFlags        = 0;

        HRESULT dxhr = device->CreateTexture2D(&desc, nullptr, &m_stagingTexture);
        if (FAILED(dxhr)) {
            // Fallback to BGRA
            desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
            dxhr = device->CreateTexture2D(&desc, nullptr, &m_stagingTexture);
        }
        if (FAILED(dxhr)) {
            printf("[QSV] CreateTexture2D staging failed: 0x%lx\n", dxhr);
            destroy();
            return false;
        }
    }

    m_initialized = true;
    m_frameIndex  = 0;
    printf("[QSV] Initialized: %dx%d @ %dfps, %d Mbps, HEVC Main, all-intra\n",
           width, height, fps, bitrateMbps);
    return true;
}

// ---------------------------------------------------------------------------
// encode
// ---------------------------------------------------------------------------
bool QsvEncoder::encode(ID3D11Texture2D* inputTexture, uint64_t timestampNs)
{
    if (!m_initialized || !inputTexture || !m_transform) return false;

    // Copy input to staging texture
    ID3D11DeviceContext* ctx = nullptr;
    m_device->GetImmediateContext(&ctx);
    if (!ctx) return false;
    ctx->CopyResource(m_stagingTexture, inputTexture);
    ctx->Release();

    // Create MF sample from the staging texture
    IMFSample* inputSample = nullptr;
    IMFMediaBuffer* inputBuffer = nullptr;
    HRESULT hr;

    hr = MFCreateDXGISurfaceBuffer(
        __uuidof(ID3D11Texture2D),
        m_stagingTexture, 0, FALSE, &inputBuffer);
    if (FAILED(hr)) {
        printf("[QSV] MFCreateDXGISurfaceBuffer failed: 0x%lx\n", hr);
        return false;
    }

    hr = MFCreateSample(&inputSample);
    if (FAILED(hr)) {
        safeRelease(inputBuffer);
        return false;
    }

    inputSample->AddBuffer(inputBuffer);

    // Set timestamp (100ns units for MF)
    int64_t mfTimestamp = static_cast<int64_t>(timestampNs / 100);
    inputSample->SetSampleTime(mfTimestamp);

    // Set duration
    int64_t durationHns = 10'000'000LL / m_fps; // 100ns units
    inputSample->SetSampleDuration(durationHns);

    // Force keyframe (since we want all-intra)
    // Set the CODECAPI property for force-keyframe via sample attribute
    inputSample->SetUINT32(MFSampleExtension_CleanPoint, TRUE);

    // Submit input
    hr = m_transform->ProcessInput(m_inputStreamID, inputSample, 0);
    safeRelease(inputBuffer);
    safeRelease(inputSample);

    if (FAILED(hr)) {
        printf("[QSV] ProcessInput failed: 0x%lx\n", hr);
        return false;
    }

    // Collect output
    MFT_OUTPUT_DATA_BUFFER outputDataBuffer = {};
    outputDataBuffer.dwStreamID = m_outputStreamID;

    // Check if the MFT allocates its own output samples
    MFT_OUTPUT_STREAM_INFO streamInfo = {};
    hr = m_transform->GetOutputStreamInfo(m_outputStreamID, &streamInfo);

    bool mftAllocatesOutput = (streamInfo.dwFlags &
        (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;

    IMFSample* outputSample = nullptr;
    IMFMediaBuffer* outputBuffer = nullptr;

    if (!mftAllocatesOutput) {
        // We need to provide the output sample
        hr = MFCreateSample(&outputSample);
        if (FAILED(hr)) return false;

        DWORD bufSize = std::max(streamInfo.cbSize, static_cast<DWORD>(m_width * m_height * 2));
        hr = MFCreateMemoryBuffer(bufSize, &outputBuffer);
        if (FAILED(hr)) {
            safeRelease(outputSample);
            return false;
        }

        outputSample->AddBuffer(outputBuffer);
        outputDataBuffer.pSample = outputSample;
    }

    DWORD status = 0;
    hr = m_transform->ProcessOutput(0, 1, &outputDataBuffer, &status);

    if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) {
        // Encoder needs more data before producing output
        safeRelease(outputBuffer);
        safeRelease(outputSample);
        return true; // Not an error
    }

    if (FAILED(hr)) {
        printf("[QSV] ProcessOutput failed: 0x%lx\n", hr);
        safeRelease(outputBuffer);
        safeRelease(outputSample);
        if (outputDataBuffer.pEvents) outputDataBuffer.pEvents->Release();
        return false;
    }

    // Extract encoded data
    IMFSample* resultSample = outputDataBuffer.pSample;
    if (resultSample) {
        IMFMediaBuffer* resultBuffer = nullptr;
        hr = resultSample->ConvertToContiguousBuffer(&resultBuffer);
        if (SUCCEEDED(hr) && resultBuffer) {
            BYTE* rawData = nullptr;
            DWORD rawSize = 0;

            hr = resultBuffer->Lock(&rawData, nullptr, &rawSize);
            if (SUCCEEDED(hr) && rawData && rawSize > 0) {
                // Convert to Annex-B format
                convertToAnnexB(rawData, rawSize, m_annexBBuffer);

                // Check if keyframe (with all-intra, every frame should be)
                UINT32 isCleanPoint = 0;
                resultSample->GetUINT32(MFSampleExtension_CleanPoint, &isCleanPoint);
                bool isKeyframe = (isCleanPoint != 0) || true; // all-intra = always keyframe

                deliverOutput(m_annexBBuffer.data(), m_annexBBuffer.size(),
                              timestampNs, isKeyframe);

                resultBuffer->Unlock();
            }
            safeRelease(resultBuffer);
        }
    }

    // Clean up
    if (outputDataBuffer.pEvents) outputDataBuffer.pEvents->Release();
    // Only release if we allocated; if MFT provided it, it might reuse it
    if (!mftAllocatesOutput) {
        safeRelease(outputBuffer);
        safeRelease(outputSample);
    } else if (outputDataBuffer.pSample) {
        outputDataBuffer.pSample->Release();
    }

    m_frameIndex++;
    return true;
}

// ---------------------------------------------------------------------------
// convertToAnnexB
// ---------------------------------------------------------------------------
void QsvEncoder::convertToAnnexB(const uint8_t* input, size_t inputSize,
                                  std::vector<uint8_t>& output)
{
    output.clear();
    if (inputSize < 4) return;

    // Check if already Annex-B (starts with 0x00000001 or 0x000001)
    if ((input[0] == 0x00 && input[1] == 0x00 && input[2] == 0x00 && input[3] == 0x01) ||
        (input[0] == 0x00 && input[1] == 0x00 && input[2] == 0x01)) {
        output.assign(input, input + inputSize);
        return;
    }

    // Length-prefixed NAL units (HVCC format) → Annex-B
    output.reserve(inputSize + 64);
    size_t offset = 0;

    while (offset + m_nalLengthSize <= inputSize) {
        uint32_t nalLen = 0;
        if (m_nalLengthSize == 4) {
            nalLen = (static_cast<uint32_t>(input[offset])     << 24) |
                     (static_cast<uint32_t>(input[offset + 1]) << 16) |
                     (static_cast<uint32_t>(input[offset + 2]) <<  8) |
                     (static_cast<uint32_t>(input[offset + 3]));
        } else if (m_nalLengthSize == 2) {
            nalLen = (static_cast<uint32_t>(input[offset])     << 8) |
                     (static_cast<uint32_t>(input[offset + 1]));
        } else {
            nalLen = input[offset];
        }
        offset += m_nalLengthSize;

        if (nalLen == 0 || offset + nalLen > inputSize) break;

        // 4-byte Annex-B start code
        output.push_back(0x00);
        output.push_back(0x00);
        output.push_back(0x00);
        output.push_back(0x01);

        output.insert(output.end(), input + offset, input + offset + nalLen);
        offset += nalLen;
    }

    // If conversion produced nothing (bad format), just prepend start code
    // to the entire buffer as a last resort
    if (output.empty() && inputSize > 0) {
        output.reserve(inputSize + 4);
        output.push_back(0x00);
        output.push_back(0x00);
        output.push_back(0x00);
        output.push_back(0x01);
        output.insert(output.end(), input, input + inputSize);
    }
}

// ---------------------------------------------------------------------------
// updateSettings
// ---------------------------------------------------------------------------
void QsvEncoder::updateSettings(int bitrateMbps, float quality, bool gamingBoost)
{
    if (!m_initialized || !m_transform) return;

    if (gamingBoost) {
        bitrateMbps = Config::GAMING_BOOST_BITRATE;
        quality     = Config::GAMING_BOOST_QUALITY;
    }

    bitrateMbps = std::clamp(bitrateMbps, Config::MIN_BITRATE_MBPS, Config::MAX_BITRATE_MBPS);
    m_bitrateMbps = bitrateMbps;

    // Update via ICodecAPI
    ICodecAPI* codecAPI = nullptr;
    HRESULT hr = m_transform->QueryInterface(IID_ICodecAPI,
                                             reinterpret_cast<void**>(&codecAPI));
    if (SUCCEEDED(hr) && codecAPI) {
        VARIANT var;

        // Mean bitrate
        VariantInit(&var);
        var.vt = VT_UI4;
        var.ulVal = static_cast<ULONG>(bitrateMbps) * 1'000'000u;
        codecAPI->SetValue(&CODECAPI_AVEncCommonMeanBitRate, &var);

        // Max bitrate
        VariantInit(&var);
        var.vt = VT_UI4;
        var.ulVal = static_cast<ULONG>(bitrateMbps) * 1'500'000u;
        codecAPI->SetValue(&CODECAPI_AVEncCommonMaxBitRate, &var);

        codecAPI->Release();

        printf("[QSV] Updated: %d Mbps, quality=%.2f, gaming=%d\n",
               bitrateMbps, quality, gamingBoost);
    }
}

// ---------------------------------------------------------------------------
// flush
// ---------------------------------------------------------------------------
void QsvEncoder::flush()
{
    if (!m_initialized || !m_transform) return;

    m_transform->ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0);

    // Drain remaining output
    MFT_OUTPUT_DATA_BUFFER outputDataBuffer = {};
    outputDataBuffer.dwStreamID = m_outputStreamID;
    DWORD status = 0;

    while (true) {
        MFT_OUTPUT_STREAM_INFO streamInfo = {};
        m_transform->GetOutputStreamInfo(m_outputStreamID, &streamInfo);

        bool mftAllocates = (streamInfo.dwFlags &
            (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;

        IMFSample* outSample = nullptr;
        IMFMediaBuffer* outBuf = nullptr;

        if (!mftAllocates) {
            MFCreateSample(&outSample);
            DWORD bufSize = std::max(streamInfo.cbSize, static_cast<DWORD>(m_width * m_height));
            MFCreateMemoryBuffer(bufSize, &outBuf);
            if (outSample && outBuf) outSample->AddBuffer(outBuf);
            outputDataBuffer.pSample = outSample;
        } else {
            outputDataBuffer.pSample = nullptr;
        }

        HRESULT hr = m_transform->ProcessOutput(0, 1, &outputDataBuffer, &status);
        if (FAILED(hr)) {
            safeRelease(outBuf);
            safeRelease(outSample);
            break;
        }

        if (outputDataBuffer.pSample) {
            outputDataBuffer.pSample->Release();
        }
        if (outputDataBuffer.pEvents) {
            outputDataBuffer.pEvents->Release();
        }
        if (!mftAllocates) {
            safeRelease(outBuf);
            safeRelease(outSample);
        }
    }

    m_transform->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
}

// ---------------------------------------------------------------------------
// destroy
// ---------------------------------------------------------------------------
void QsvEncoder::destroy()
{
    if (m_transform) {
        m_transform->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
    }

    safeRelease(m_transform);

    if (m_dxgiMgr) {
        if (m_deviceHandle) {
            m_dxgiMgr->CloseDeviceHandle(m_deviceHandle);
            m_deviceHandle = nullptr;
        }
        safeRelease(m_dxgiMgr);
    }

    if (m_stagingTexture) {
        m_stagingTexture->Release();
        m_stagingTexture = nullptr;
    }

    if (m_mfStarted) {
        MFShutdown();
        m_mfStarted = false;
    }

    m_initialized = false;
}
