#pragma once

#include "VideoEncoder.h"
#include <vector>
#include <cstdint>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <atomic>
#include <queue>

// We load the NVENC API at runtime — only need the header types at compile time.
// The CMakeLists.txt optionally provides the SDK path; if not available we define
// the minimal structures inline so the file always compiles.
#ifdef HAS_NVENC
#include <nvEncodeAPI.h>
// The SDK header defines NvEncodeAPICreateInstance as a function, but we
// need a function-pointer type for GetProcAddress.
using NvEncodeAPICreateInstance_t = decltype(&NvEncodeAPICreateInstance);
#else
// -----------------------------------------------------------------------
// Minimal NVENC type stubs (enough to compile without the SDK).
// At runtime we dynamically load nvEncodeAPI64.dll and resolve function
// pointers, so these must match the real ABI layout.
// -----------------------------------------------------------------------
#include <windows.h>
#include <d3d11.h>
#include <guiddef.h>

// GUID helpers
#ifndef NVENCAPI
#define NVENCAPI
#endif

using NV_ENC_STATUS = int;
#define NV_ENC_SUCCESS                  0
#define NV_ENC_ERR_NO_ENCODE_DEVICE     1
#define NV_ENC_ERR_UNSUPPORTED_DEVICE   2
#define NV_ENC_ERR_INVALID_ENCODERDEVICE 3
#define NV_ENC_ERR_INVALID_DEVICE       4
#define NV_ENC_ERR_DEVICE_NOT_EXIST     5
#define NV_ENC_ERR_INVALID_PTR          6
#define NV_ENC_ERR_INVALID_EVENT        7
#define NV_ENC_ERR_INVALID_PARAM        8
#define NV_ENC_ERR_INVALID_CALL         9
#define NV_ENC_ERR_OUT_OF_MEMORY        10
#define NV_ENC_ERR_ENCODER_NOT_INITIALIZED 11
#define NV_ENC_ERR_UNSUPPORTED_PARAM    12
#define NV_ENC_ERR_LOCK_BUSY            13
#define NV_ENC_ERR_NOT_ENOUGH_BUFFER    14
#define NV_ENC_ERR_INVALID_VERSION      15
#define NV_ENC_ERR_MAP_FAILED           16
#define NV_ENC_ERR_NEED_MORE_INPUT      17
#define NV_ENC_ERR_ENCODER_BUSY         18
#define NV_ENC_ERR_EVENT_NOT_REGISTERD  19
#define NV_ENC_ERR_GENERIC              20

#define NVENCAPI_MAJOR_VERSION 12
#define NVENCAPI_MINOR_VERSION 2
#define NVENCAPI_VERSION       ((NVENCAPI_MAJOR_VERSION << 4) | NVENCAPI_MINOR_VERSION)

#define NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER   \
    (sizeof(NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS) | (NVENCAPI_VERSION << 16))
#define NV_ENC_INITIALIZE_PARAMS_VER \
    (sizeof(NV_ENC_INITIALIZE_PARAMS) | (NVENCAPI_VERSION << 16))
#define NV_ENC_CONFIG_VER \
    (sizeof(NV_ENC_CONFIG) | (NVENCAPI_VERSION << 16))
#define NV_ENC_PRESET_CONFIG_VER \
    (sizeof(NV_ENC_PRESET_CONFIG) | (NVENCAPI_VERSION << 16))
#define NV_ENC_CREATE_INPUT_BUFFER_VER \
    (sizeof(NV_ENC_CREATE_INPUT_BUFFER) | (NVENCAPI_VERSION << 16))
#define NV_ENC_CREATE_BITSTREAM_BUFFER_VER \
    (sizeof(NV_ENC_CREATE_BITSTREAM_BUFFER) | (NVENCAPI_VERSION << 16))
#define NV_ENC_REGISTER_RESOURCE_VER \
    (sizeof(NV_ENC_REGISTER_RESOURCE) | (NVENCAPI_VERSION << 16))
#define NV_ENC_MAP_INPUT_RESOURCE_VER \
    (sizeof(NV_ENC_MAP_INPUT_RESOURCE) | (NVENCAPI_VERSION << 16))
#define NV_ENC_PIC_PARAMS_VER \
    (sizeof(NV_ENC_PIC_PARAMS) | (NVENCAPI_VERSION << 16))
#define NV_ENC_LOCK_BITSTREAM_VER \
    (sizeof(NV_ENC_LOCK_BITSTREAM) | (NVENCAPI_VERSION << 16))
#define NV_ENC_RECONFIGURE_PARAMS_VER \
    (sizeof(NV_ENC_RECONFIGURE_PARAMS) | (NVENCAPI_VERSION << 16))

// Device types
#define NV_ENC_DEVICE_TYPE_DIRECTX  1

// Buffer formats
#define NV_ENC_BUFFER_FORMAT_ARGB    0x00000020
#define NV_ENC_BUFFER_FORMAT_NV12    0x00000001

// Resource types
#define NV_ENC_INPUT_RESOURCE_TYPE_DIRECTX 0

// Tuning info
#define NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY 1

// Picture types
#define NV_ENC_PIC_TYPE_IDR  4

// Encode picture flags
#define NV_ENC_PIC_FLAG_FORCEIDR       0x01
#define NV_ENC_PIC_FLAG_OUTPUT_SPSPPS  0x04
#define NV_ENC_PIC_FLAG_EOS            0x08

// Picture struct
#define NV_ENC_PIC_STRUCT_FRAME 1

// Codec specific flags
#define NV_ENC_HEVC_PROFILE_MAIN_GUID \
    { 0xB514C39A, 0xB55B, 0x40FA, { 0x87, 0x8F, 0xF1, 0x25, 0x3B, 0x4D, 0xFD, 0xEC } }

#define NV_ENC_CODEC_HEVC_GUID \
    { 0x790CDC88, 0x4522, 0x4D7B, { 0x94, 0x25, 0xBD, 0xA9, 0x97, 0x5F, 0x76, 0x03 } }

#define NV_ENC_PRESET_P1_GUID \
    { 0xFC0A8D3E, 0xE7B3, 0x44B8, { 0x98, 0x01, 0xF0, 0x48, 0x99, 0x3A, 0xE2, 0xDB } }

#define NV_ENC_PRESET_P4_GUID \
    { 0xB2FC312F, 0x297A, 0x4A04, { 0xB5, 0x52, 0x0A, 0x88, 0x4E, 0x1D, 0x27, 0xD8 } }

// Rate control modes
#define NV_ENC_PARAMS_RC_CBR        2
#define NV_ENC_PARAMS_RC_VBR        1

// Structures (simplified — must match real struct layout offsets)
// In a real build the SDK header provides these; these stubs let us compile
// without it and still use runtime-loaded function pointers correctly.

struct NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS {
    uint32_t version;
    uint32_t deviceType;
    void*    device;
    void*    reserved;
    uint32_t apiVersion;
    uint32_t reserved1[253];
};

struct NV_ENC_CONFIG_HEVC {
    uint32_t level;
    uint32_t tier;
    uint32_t minCUSize;
    uint32_t maxCUSize;
    uint32_t sliceMode;
    uint32_t sliceModeData;
    uint32_t maxTemporalLayersMinus1;
    uint32_t chromaFormatIDC;
    uint32_t pixelBitDepthMinus8;
    uint32_t reserved1[219];
};

struct NV_ENC_CONFIG_HEVC_EXT {
    // placeholder for extended HEVC config
    uint32_t reserved[256];
};

struct NV_ENC_RC_PARAMS {
    uint32_t version;
    uint32_t rateControlMode;
    uint32_t constQP_interP;
    uint32_t constQP_interB;
    uint32_t constQP_intra;
    uint32_t averageBitRate;
    uint32_t maxBitRate;
    uint32_t vbvBufferSize;
    uint32_t vbvInitialDelay;
    uint32_t reserved[247];
};

struct NV_ENC_CODEC_CONFIG {
    union {
        NV_ENC_CONFIG_HEVC hevcConfig;
        uint32_t reserved[256];
    };
};

struct NV_ENC_CONFIG {
    uint32_t          version;
    GUID              profileGUID;
    uint32_t          gopLength;
    int32_t           frameIntervalP; // 0 = all intra
    uint32_t          monoChromeEncoding;
    uint32_t          frameFieldMode;
    NV_ENC_RC_PARAMS  rcParams;
    NV_ENC_CODEC_CONFIG encodeCodecConfig;
    uint32_t          reserved[278];
};

struct NV_ENC_INITIALIZE_PARAMS {
    uint32_t version;
    GUID     encodeGUID;
    GUID     presetGUID;
    uint32_t encodeWidth;
    uint32_t encodeHeight;
    uint32_t darWidth;
    uint32_t darHeight;
    uint32_t frameRateNum;
    uint32_t frameRateDen;
    uint32_t enableEncodeAsync;
    uint32_t enablePTD;
    uint32_t reportSliceOffsets;
    uint32_t enableSubFrameWrite;
    uint32_t enableExternalMEHints;
    uint32_t enableMEOnlyMode;
    uint32_t enableWeightedPrediction;
    uint32_t enableOutputInVidmem;
    uint32_t reserved1a;
    uint32_t privDataSize;
    void*    privData;
    NV_ENC_CONFIG* encodeConfig;
    uint32_t maxEncodeWidth;
    uint32_t maxEncodeHeight;
    uint32_t tuningInfo;
    uint32_t reserved[289];
};

struct NV_ENC_PRESET_CONFIG {
    uint32_t      version;
    NV_ENC_CONFIG presetCfg;
    uint32_t      reserved[254];
};

struct NV_ENC_REGISTER_RESOURCE {
    uint32_t version;
    uint32_t resourceType;
    uint32_t width;
    uint32_t height;
    uint32_t pitch;
    uint32_t subResourceIndex;
    void*    resourceToRegister;
    void*    registeredResource;
    uint32_t bufferFormat;
    uint32_t bufferUsage;
    uint32_t reserved[247];
};

struct NV_ENC_MAP_INPUT_RESOURCE {
    uint32_t version;
    uint32_t subResourceIndex;
    void*    registeredResource;
    void*    mappedResource;
    uint32_t mappedBufferFmt;
    uint32_t reserved[251];
};

struct NV_ENC_CREATE_BITSTREAM_BUFFER {
    uint32_t version;
    uint32_t size;
    uint32_t memoryHeap;
    void*    bitstreamBuffer;
    void*    bitstreamBufferPtr;
    uint32_t reserved[250];
};

struct NV_ENC_PIC_PARAMS {
    uint32_t version;
    uint32_t inputWidth;
    uint32_t inputHeight;
    uint32_t inputPitch;
    uint32_t encodePicFlags;
    uint32_t frameIdx;
    uint64_t inputTimeStamp;
    uint64_t inputDuration;
    void*    inputBuffer;
    void*    outputBitstream;
    void*    completionEvent;
    uint32_t bufferFmt;
    uint32_t pictureStruct;
    uint32_t pictureType;
    NV_ENC_CODEC_CONFIG codecPicParams;
    uint32_t reserved[286];
};

struct NV_ENC_LOCK_BITSTREAM {
    uint32_t  version;
    uint32_t  doNotWait;
    void*     outputBitstream;
    uint32_t* sliceOffsets;
    uint32_t  frameIdx;
    uint32_t  hwEncodeStatus;
    uint32_t  numSlices;
    uint32_t  bitstreamSizeInBytes;
    uint64_t  outputTimeStamp;
    uint64_t  outputDuration;
    void*     bitstreamBufferPtr;
    uint32_t  pictureType;
    uint32_t  pictureStruct;
    uint32_t  frameAvgQP;
    uint32_t  frameSatd;
    uint32_t  ltrFrameIdx;
    uint32_t  ltrFrameBitmap;
    uint32_t  reserved[230];
};

struct NV_ENC_RECONFIGURE_PARAMS {
    uint32_t                version;
    NV_ENC_INITIALIZE_PARAMS reInitEncodeParams;
    uint32_t                resetEncoder;
    uint32_t                forceIDR;
    uint32_t                reserved[254];
};

// Function list structure
struct NV_ENCODE_API_FUNCTION_LIST {
    uint32_t      version;
    uint32_t      reserved;
    NV_ENC_STATUS (NVENCAPI *nvEncOpenEncodeSessionEx)(NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS* params, void** encoder);
    NV_ENC_STATUS (NVENCAPI *nvEncGetEncodeGUIDCount)(void* encoder, uint32_t* count);
    NV_ENC_STATUS (NVENCAPI *nvEncGetEncodeGUIDs)(void* encoder, GUID* guids, uint32_t count, uint32_t* outCount);
    NV_ENC_STATUS (NVENCAPI *nvEncGetEncodeProfileGUIDCount)(void* encoder, GUID encodeGUID, uint32_t* count);
    NV_ENC_STATUS (NVENCAPI *nvEncGetEncodeProfileGUIDs)(void* encoder, GUID encodeGUID, GUID* guids, uint32_t count, uint32_t* outCount);
    NV_ENC_STATUS (NVENCAPI *nvEncGetInputFormatCount)(void* encoder, GUID encodeGUID, uint32_t* count);
    NV_ENC_STATUS (NVENCAPI *nvEncGetInputFormats)(void* encoder, GUID encodeGUID, uint32_t* formats, uint32_t count, uint32_t* outCount);
    NV_ENC_STATUS (NVENCAPI *nvEncGetEncodeCaps)(void* encoder, GUID encodeGUID, void* capsParam, int* capsVal);
    NV_ENC_STATUS (NVENCAPI *nvEncGetEncodePresetCount)(void* encoder, GUID encodeGUID, uint32_t* count);
    NV_ENC_STATUS (NVENCAPI *nvEncGetEncodePresetGUIDs)(void* encoder, GUID encodeGUID, GUID* guids, uint32_t count, uint32_t* outCount);
    NV_ENC_STATUS (NVENCAPI *nvEncGetEncodePresetConfigEx)(void* encoder, GUID encodeGUID, GUID presetGUID, uint32_t tuningInfo, NV_ENC_PRESET_CONFIG* presetConfig);
    NV_ENC_STATUS (NVENCAPI *nvEncInitializeEncoder)(void* encoder, NV_ENC_INITIALIZE_PARAMS* params);
    NV_ENC_STATUS (NVENCAPI *nvEncCreateInputBuffer)(void* encoder, void* createInputBufferParams);
    NV_ENC_STATUS (NVENCAPI *nvEncDestroyInputBuffer)(void* encoder, void* inputBuffer);
    NV_ENC_STATUS (NVENCAPI *nvEncCreateBitstreamBuffer)(void* encoder, NV_ENC_CREATE_BITSTREAM_BUFFER* params);
    NV_ENC_STATUS (NVENCAPI *nvEncDestroyBitstreamBuffer)(void* encoder, void* bitstreamBuffer);
    NV_ENC_STATUS (NVENCAPI *nvEncEncodePicture)(void* encoder, NV_ENC_PIC_PARAMS* params);
    NV_ENC_STATUS (NVENCAPI *nvEncLockBitstream)(void* encoder, NV_ENC_LOCK_BITSTREAM* params);
    NV_ENC_STATUS (NVENCAPI *nvEncUnlockBitstream)(void* encoder, void* bitstreamBuffer);
    NV_ENC_STATUS (NVENCAPI *nvEncLockInputBuffer)(void* encoder, void* lockInputBufferParams);
    NV_ENC_STATUS (NVENCAPI *nvEncUnlockInputBuffer)(void* encoder, void* inputBuffer);
    NV_ENC_STATUS (NVENCAPI *nvEncGetEncodeStats)(void* encoder, void* stats);
    NV_ENC_STATUS (NVENCAPI *nvEncGetSequenceParams)(void* encoder, void* seqParams);
    void*         nvEncRegisterAsyncEvent;
    void*         nvEncUnregisterAsyncEvent;
    NV_ENC_STATUS (NVENCAPI *nvEncMapInputResource)(void* encoder, NV_ENC_MAP_INPUT_RESOURCE* params);
    NV_ENC_STATUS (NVENCAPI *nvEncUnmapInputResource)(void* encoder, void* mappedResource);
    NV_ENC_STATUS (NVENCAPI *nvEncDestroyEncoder)(void* encoder);
    void*         nvEncInvalidateRefFrames;
    void*         nvEncOpenEncodeSessionEx2;
    NV_ENC_STATUS (NVENCAPI *nvEncRegisterResource)(void* encoder, NV_ENC_REGISTER_RESOURCE* params);
    NV_ENC_STATUS (NVENCAPI *nvEncUnregisterResource)(void* encoder, void* resource);
    NV_ENC_STATUS (NVENCAPI *nvEncReconfigureEncoder)(void* encoder, NV_ENC_RECONFIGURE_PARAMS* params);
    void*         reserved2[277];
};

#define NV_ENCODE_API_FUNCTION_LIST_VER \
    (sizeof(NV_ENCODE_API_FUNCTION_LIST) | (NVENCAPI_VERSION << 16))

using NvEncodeAPICreateInstance_t = NV_ENC_STATUS(NVENCAPI*)(NV_ENCODE_API_FUNCTION_LIST*);

#endif // !HAS_NVENC


/// NVIDIA NVENC H.265 encoder.
/// Dynamically loads nvEncodeAPI64.dll at runtime.
class NvencEncoder : public VideoEncoder {
public:
    NvencEncoder();
    ~NvencEncoder() override;

    /// Attempt to open the NVENC session. Returns false if NVIDIA GPU / driver
    /// not available.
    bool initialize(ID3D11Device* device, int width, int height,
                    int fps, int bitrateMbps);

    bool encode(ID3D11Texture2D* inputTexture, uint64_t timestampNs) override;
    void updateSettings(int bitrateMbps, float quality, bool gamingBoost) override;
    void flush() override;
    std::string encoderName() const override { return "NVENC"; }

private:
    void destroy();

    /// Encode thread function — processes queued frames off the capture thread.
    void encodeThreadFunc();

    /// Perform the actual NVENC encode (called on encode thread).
    bool encodeInternal(int stagingIdx, uint64_t timestampNs);

    // DLL / API
    HMODULE                     m_nvencLib   = nullptr;
    NV_ENCODE_API_FUNCTION_LIST m_nvenc      = {};
    void*                       m_encoder    = nullptr;

    // D3D11 device (not owned)
    ID3D11Device*               m_device     = nullptr;

    // Resources — double-buffered staging textures so capture can copy to
    // texture[next] while NVENC encodes from texture[current].
    static constexpr int kNumStaging = 2;
    ID3D11Texture2D*  m_stagingTextures[kNumStaging] = { nullptr, nullptr };
    void*             m_registeredResources[kNumStaging] = { nullptr, nullptr };
    void*             m_bitstreamBuffers[kNumStaging]    = { nullptr, nullptr };
    int               m_stagingWrite = 0;  // index capture thread writes to

    // Encode thread
    std::thread              m_encodeThread;
    std::mutex               m_encodeMutex;
    std::condition_variable  m_encodeCV;
    struct EncodeJob {
        int stagingIdx;
        uint64_t timestampNs;
    };
    std::queue<EncodeJob>    m_encodeQueue;
    std::atomic<bool>        m_encodeRunning{false};

    // Encode config (kept for reconfigure)
    NV_ENC_INITIALIZE_PARAMS    m_initParams = {};
    NV_ENC_CONFIG               m_encodeConfig = {};

    bool m_initialized = false;
    uint32_t m_frameIndex = 0;
};
