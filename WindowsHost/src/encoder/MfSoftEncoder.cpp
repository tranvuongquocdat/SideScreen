// MfSoftEncoder.cpp — Windows Media Foundation software H.265 encoder
//
// CPU-only fallback encoder using the Microsoft HEVC software MFT that
// ships with Windows 10+.  Used when no GPU encoder is available.
//
// Output: Annex-B H.265 with 0x00000001 start codes.
// Settings: all-intra, no B-frames, low-latency, HEVC Main profile.

#include "MfSoftEncoder.h"
#include "../Config.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <d3d11.h>

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

// HEVC output format GUID
DEFINE_GUID(MFVideoFormat_HEVC_Soft,
    0x43564548, 0x0000, 0x0010, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71);

// Low-latency attribute
DEFINE_GUID(MF_LOW_LATENCY_Soft,
    0x9C27891A, 0xED7A, 0x40e1, 0x88, 0xE8, 0xB2, 0x27, 0x27, 0xA0, 0x24, 0xEE);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
template<typename T>
static void safeReleaseSoft(T*& p) {
    if (p) { p->Release(); p = nullptr; }
}

MfSoftEncoder::MfSoftEncoder() = default;

MfSoftEncoder::~MfSoftEncoder() {
    destroy();
}

// ---------------------------------------------------------------------------
// initialize
// ---------------------------------------------------------------------------
bool MfSoftEncoder::initialize(ID3D11Device* device, int width, int height,
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
        printf("[MF-Soft] MFStartup failed: 0x%lx\n", hr);
        return false;
    }
    m_mfStarted = true;

    // --- 2. Find SOFTWARE HEVC encoder MFT ---
    MFT_REGISTER_TYPE_INFO outputType = {};
    outputType.guidMajorType = MFMediaType_Video;
    outputType.guidSubtype   = MFVideoFormat_HEVC_Soft;

    IMFActivate** ppActivate = nullptr;
    UINT32 activateCount = 0;

    // Request software MFTs only (no hardware flag)
    hr = MFTEnumEx(
        MFT_CATEGORY_VIDEO_ENCODER,
        MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_ASYNCMFT |
        MFT_ENUM_FLAG_LOCALMFT | MFT_ENUM_FLAG_SORTANDFILTER,
        nullptr,       // input type: any
        &outputType,   // output type: HEVC
        &ppActivate,
        &activateCount
    );

    if (FAILED(hr) || activateCount == 0) {
        printf("[MF-Soft] No software HEVC encoder MFT found\n");
        if (ppActivate) CoTaskMemFree(ppActivate);
        destroy();
        return false;
    }

    // Activate the first software encoder
    hr = ppActivate[0]->ActivateObject(IID_IMFTransform,
                                       reinterpret_cast<void**>(&m_transform));

    for (UINT32 i = 0; i < activateCount; i++) {
        ppActivate[i]->Release();
    }
    CoTaskMemFree(ppActivate);

    if (FAILED(hr) || !m_transform) {
        printf("[MF-Soft] ActivateObject failed: 0x%lx\n", hr);
        destroy();
        return false;
    }

    // Get stream IDs
    hr = m_transform->GetStreamIDs(1, &m_inputStreamID, 1, &m_outputStreamID);
    if (hr == E_NOTIMPL) {
        m_inputStreamID = 0;
        m_outputStreamID = 0;
    }

    // --- 3. Configure output media type (HEVC) ---
    {
        IMFMediaType* outputMediaType = nullptr;
        hr = MFCreateMediaType(&outputMediaType);
        if (FAILED(hr)) { destroy(); return false; }

        outputMediaType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        outputMediaType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_HEVC_Soft);
        outputMediaType->SetUINT32(MF_MT_AVG_BITRATE,
                                   static_cast<UINT32>(bitrateMbps) * 1'000'000u);
        MFSetAttributeSize(outputMediaType, MF_MT_FRAME_SIZE, width, height);
        MFSetAttributeRatio(outputMediaType, MF_MT_FRAME_RATE, fps, 1);
        outputMediaType->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        outputMediaType->SetUINT32(MF_MT_MPEG2_PROFILE, 1); // Main profile

        hr = m_transform->SetOutputType(m_outputStreamID, outputMediaType, 0);
        safeReleaseSoft(outputMediaType);
        if (FAILED(hr)) {
            printf("[MF-Soft] SetOutputType failed: 0x%lx\n", hr);
            destroy();
            return false;
        }
    }

    // --- 4. Configure input media type (NV12 preferred, BGRA fallback) ---
    {
        IMFMediaType* inputMediaType = nullptr;
        hr = MFCreateMediaType(&inputMediaType);
        if (FAILED(hr)) { destroy(); return false; }

        inputMediaType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        inputMediaType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
        MFSetAttributeSize(inputMediaType, MF_MT_FRAME_SIZE, width, height);
        MFSetAttributeRatio(inputMediaType, MF_MT_FRAME_RATE, fps, 1);
        inputMediaType->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);

        hr = m_transform->SetInputType(m_inputStreamID, inputMediaType, 0);
        if (FAILED(hr)) {
            // Fallback to ARGB32/BGRA
            inputMediaType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_ARGB32);
            hr = m_transform->SetInputType(m_inputStreamID, inputMediaType, 0);
        }
        safeReleaseSoft(inputMediaType);
        if (FAILED(hr)) {
            printf("[MF-Soft] SetInputType failed: 0x%lx\n", hr);
            destroy();
            return false;
        }
    }

    // --- 5. Configure encoder settings via ICodecAPI ---
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

    // --- 6. Set low-latency attribute on the transform ---
    {
        IMFAttributes* attrs = nullptr;
        hr = m_transform->GetAttributes(&attrs);
        if (SUCCEEDED(hr) && attrs) {
            attrs->SetUINT32(MF_LOW_LATENCY_Soft, TRUE);
            attrs->Release();
        }
    }

    // --- 7. Start streaming ---
    hr = m_transform->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    if (FAILED(hr)) {
        printf("[MF-Soft] BEGIN_STREAMING failed: 0x%lx (non-fatal)\n", hr);
    }

    hr = m_transform->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    if (FAILED(hr)) {
        printf("[MF-Soft] START_OF_STREAM failed: 0x%lx\n", hr);
    }

    // --- 8. Create CPU-readable staging texture ---
    // Software encoder needs CPU access, so we use a staging texture
    // with CPU read access to copy GPU texture → CPU memory.
    {
        D3D11_TEXTURE2D_DESC desc = {};
        desc.Width            = static_cast<UINT>(width);
        desc.Height           = static_cast<UINT>(height);
        desc.MipLevels        = 1;
        desc.ArraySize        = 1;
        desc.Format           = DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.Usage            = D3D11_USAGE_STAGING;
        desc.CPUAccessFlags   = D3D11_CPU_ACCESS_READ;
        desc.BindFlags        = 0;

        HRESULT dxhr = device->CreateTexture2D(&desc, nullptr, &m_stagingTexture);
        if (FAILED(dxhr)) {
            printf("[MF-Soft] CreateTexture2D staging failed: 0x%lx\n", dxhr);
            destroy();
            return false;
        }
    }

    m_initialized = true;
    m_frameIndex  = 0;
    printf("[MF-Soft] Initialized: %dx%d @ %dfps, %d Mbps, HEVC Main, all-intra (CPU)\n",
           width, height, fps, bitrateMbps);
    printf("[MF-Soft] WARNING: Software encoding is slow. Consider using a GPU with hardware encoder support.\n");
    return true;
}

// ---------------------------------------------------------------------------
// encode
// ---------------------------------------------------------------------------
bool MfSoftEncoder::encode(ID3D11Texture2D* inputTexture, uint64_t timestampNs)
{
    if (!m_initialized || !inputTexture || !m_transform) return false;

    // Copy GPU texture to CPU-readable staging texture
    ID3D11DeviceContext* ctx = nullptr;
    m_device->GetImmediateContext(&ctx);
    if (!ctx) return false;
    ctx->CopyResource(m_stagingTexture, inputTexture);

    // Map staging texture to get CPU pointer
    D3D11_MAPPED_SUBRESOURCE mapped = {};
    HRESULT hr = ctx->Map(m_stagingTexture, 0, D3D11_MAP_READ, 0, &mapped);
    ctx->Release();
    if (FAILED(hr)) {
        printf("[MF-Soft] Map staging texture failed: 0x%lx\n", hr);
        return false;
    }

    // Create MF sample with memory buffer containing the pixel data
    IMFSample* inputSample = nullptr;
    IMFMediaBuffer* inputBuffer = nullptr;
    DWORD frameSize = static_cast<DWORD>(mapped.RowPitch * m_height);

    hr = MFCreateMemoryBuffer(frameSize, &inputBuffer);
    if (FAILED(hr)) {
        ctx = nullptr;
        m_device->GetImmediateContext(&ctx);
        if (ctx) { ctx->Unmap(m_stagingTexture, 0); ctx->Release(); }
        return false;
    }

    // Copy pixel data into MF buffer
    BYTE* bufData = nullptr;
    hr = inputBuffer->Lock(&bufData, nullptr, nullptr);
    if (SUCCEEDED(hr)) {
        memcpy(bufData, mapped.pData, frameSize);
        inputBuffer->Unlock();
        inputBuffer->SetCurrentLength(frameSize);
    }

    // Unmap staging texture
    {
        ID3D11DeviceContext* unmapCtx = nullptr;
        m_device->GetImmediateContext(&unmapCtx);
        if (unmapCtx) { unmapCtx->Unmap(m_stagingTexture, 0); unmapCtx->Release(); }
    }

    hr = MFCreateSample(&inputSample);
    if (FAILED(hr)) {
        safeReleaseSoft(inputBuffer);
        return false;
    }

    inputSample->AddBuffer(inputBuffer);

    // Set timestamp (100ns units for MF)
    int64_t mfTimestamp = static_cast<int64_t>(timestampNs / 100);
    inputSample->SetSampleTime(mfTimestamp);

    // Set duration
    int64_t durationHns = 10'000'000LL / m_fps;
    inputSample->SetSampleDuration(durationHns);

    // Force keyframe
    inputSample->SetUINT32(MFSampleExtension_CleanPoint, TRUE);

    // Submit input
    hr = m_transform->ProcessInput(m_inputStreamID, inputSample, 0);
    safeReleaseSoft(inputBuffer);
    safeReleaseSoft(inputSample);

    if (FAILED(hr)) {
        printf("[MF-Soft] ProcessInput failed: 0x%lx\n", hr);
        return false;
    }

    // Collect output
    MFT_OUTPUT_DATA_BUFFER outputDataBuffer = {};
    outputDataBuffer.dwStreamID = m_outputStreamID;

    MFT_OUTPUT_STREAM_INFO streamInfo = {};
    hr = m_transform->GetOutputStreamInfo(m_outputStreamID, &streamInfo);

    bool mftAllocatesOutput = (streamInfo.dwFlags &
        (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;

    IMFSample* outputSample = nullptr;
    IMFMediaBuffer* outputBuffer = nullptr;

    if (!mftAllocatesOutput) {
        hr = MFCreateSample(&outputSample);
        if (FAILED(hr)) return false;

        DWORD bufSize = std::max(streamInfo.cbSize, static_cast<DWORD>(m_width * m_height * 2));
        hr = MFCreateMemoryBuffer(bufSize, &outputBuffer);
        if (FAILED(hr)) {
            safeReleaseSoft(outputSample);
            return false;
        }

        outputSample->AddBuffer(outputBuffer);
        outputDataBuffer.pSample = outputSample;
    }

    DWORD status = 0;
    hr = m_transform->ProcessOutput(0, 1, &outputDataBuffer, &status);

    if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) {
        safeReleaseSoft(outputBuffer);
        safeReleaseSoft(outputSample);
        return true;
    }

    if (FAILED(hr)) {
        printf("[MF-Soft] ProcessOutput failed: 0x%lx\n", hr);
        safeReleaseSoft(outputBuffer);
        safeReleaseSoft(outputSample);
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
                convertToAnnexB(rawData, rawSize, m_annexBBuffer);

                UINT32 isCleanPoint = 0;
                resultSample->GetUINT32(MFSampleExtension_CleanPoint, &isCleanPoint);
                bool isKeyframe = (isCleanPoint != 0) || true;

                deliverOutput(m_annexBBuffer.data(), m_annexBBuffer.size(),
                              timestampNs, isKeyframe);

                resultBuffer->Unlock();
            }
            safeReleaseSoft(resultBuffer);
        }
    }

    if (outputDataBuffer.pEvents) outputDataBuffer.pEvents->Release();
    if (!mftAllocatesOutput) {
        safeReleaseSoft(outputBuffer);
        safeReleaseSoft(outputSample);
    } else if (outputDataBuffer.pSample) {
        outputDataBuffer.pSample->Release();
    }

    m_frameIndex++;
    return true;
}

// ---------------------------------------------------------------------------
// convertToAnnexB
// ---------------------------------------------------------------------------
void MfSoftEncoder::convertToAnnexB(const uint8_t* input, size_t inputSize,
                                     std::vector<uint8_t>& output)
{
    output.clear();
    if (inputSize < 4) return;

    // Check if already Annex-B
    if ((input[0] == 0x00 && input[1] == 0x00 && input[2] == 0x00 && input[3] == 0x01) ||
        (input[0] == 0x00 && input[1] == 0x00 && input[2] == 0x01)) {
        output.assign(input, input + inputSize);
        return;
    }

    // Length-prefixed NAL units → Annex-B
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

        output.push_back(0x00);
        output.push_back(0x00);
        output.push_back(0x00);
        output.push_back(0x01);

        output.insert(output.end(), input + offset, input + offset + nalLen);
        offset += nalLen;
    }

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
void MfSoftEncoder::updateSettings(int bitrateMbps, float quality, bool gamingBoost)
{
    if (!m_initialized || !m_transform) return;

    if (gamingBoost) {
        bitrateMbps = Config::GAMING_BOOST_BITRATE;
        quality     = Config::GAMING_BOOST_QUALITY;
    }

    bitrateMbps = std::clamp(bitrateMbps, Config::MIN_BITRATE_MBPS, Config::MAX_BITRATE_MBPS);
    m_bitrateMbps = bitrateMbps;

    ICodecAPI* codecAPI = nullptr;
    HRESULT hr = m_transform->QueryInterface(IID_ICodecAPI,
                                             reinterpret_cast<void**>(&codecAPI));
    if (SUCCEEDED(hr) && codecAPI) {
        VARIANT var;

        VariantInit(&var);
        var.vt = VT_UI4;
        var.ulVal = static_cast<ULONG>(bitrateMbps) * 1'000'000u;
        codecAPI->SetValue(&CODECAPI_AVEncCommonMeanBitRate, &var);

        VariantInit(&var);
        var.vt = VT_UI4;
        var.ulVal = static_cast<ULONG>(bitrateMbps) * 1'500'000u;
        codecAPI->SetValue(&CODECAPI_AVEncCommonMaxBitRate, &var);

        codecAPI->Release();

        printf("[MF-Soft] Updated: %d Mbps, quality=%.2f, gaming=%d\n",
               bitrateMbps, quality, gamingBoost);
    }
}

// ---------------------------------------------------------------------------
// flush
// ---------------------------------------------------------------------------
void MfSoftEncoder::flush()
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
            safeReleaseSoft(outBuf);
            safeReleaseSoft(outSample);
            break;
        }

        if (outputDataBuffer.pSample) {
            outputDataBuffer.pSample->Release();
        }
        if (outputDataBuffer.pEvents) {
            outputDataBuffer.pEvents->Release();
        }
        if (!mftAllocates) {
            safeReleaseSoft(outBuf);
            safeReleaseSoft(outSample);
        }
    }

    m_transform->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
}

// ---------------------------------------------------------------------------
// destroy
// ---------------------------------------------------------------------------
void MfSoftEncoder::destroy()
{
    if (m_transform) {
        m_transform->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
    }

    safeReleaseSoft(m_transform);

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
