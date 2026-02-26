// VaapiEncoder.cpp — Direct VA-API H.265/HEVC encoder
//
// Uses libva + libva-drm to encode frames via the GPU's hardware encoder.
// Output: Annex-B H.265 with 0x00000001 start codes, VPS/SPS/PPS on every
// IDR frame.
//
// Matching macOS VideoToolbox / Windows NVENC settings:
//   - All-intra (every frame is IDR, intra_period=1)
//   - No B-frames (ip_period=1)
//   - VBR rate control
//   - HEVC Main profile
//   - Zero latency

#ifdef HAS_VAAPI

#include "VaapiEncoder.h"
#include "../Config.h"

#include <fcntl.h>
#include <unistd.h>
#include <cstdio>
#include <cstring>
#include <algorithm>
#include <vector>

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// BGRA-to-NV12 conversion (simple BT.601).
/// We convert in-place into mapped VA surface memory.
static void bgraToNV12(const uint8_t* bgra, int width, int height, int srcStride,
                       uint8_t* yPlane, int yStride,
                       uint8_t* uvPlane, int uvStride)
{
    // Y plane
    for (int y = 0; y < height; ++y) {
        const uint8_t* row = bgra + y * srcStride;
        uint8_t* yRow = yPlane + y * yStride;
        for (int x = 0; x < width; ++x) {
            uint8_t b = row[x * 4 + 0];
            uint8_t g = row[x * 4 + 1];
            uint8_t r = row[x * 4 + 2];
            // BT.601: Y = 0.299*R + 0.587*G + 0.114*B
            int yVal = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
            yRow[x] = static_cast<uint8_t>(std::clamp(yVal, 0, 255));
        }
    }

    // UV plane (NV12: interleaved U,V, half resolution)
    for (int y = 0; y < height / 2; ++y) {
        const uint8_t* row0 = bgra + (y * 2) * srcStride;
        const uint8_t* row1 = bgra + (y * 2 + 1) * srcStride;
        uint8_t* uvRow = uvPlane + y * uvStride;
        for (int x = 0; x < width / 2; ++x) {
            // Average 2x2 block
            int b = 0, g = 0, r = 0;
            for (int dy = 0; dy < 2; ++dy) {
                const uint8_t* src = (dy == 0) ? row0 : row1;
                for (int dx = 0; dx < 2; ++dx) {
                    int px = (x * 2 + dx) * 4;
                    b += src[px + 0];
                    g += src[px + 1];
                    r += src[px + 2];
                }
            }
            b /= 4; g /= 4; r /= 4;

            // BT.601: U = (-38*R - 74*G + 112*B + 128) >> 8 + 128
            //         V = (112*R - 94*G - 18*B + 128) >> 8 + 128
            int u = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
            int v = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
            uvRow[x * 2 + 0] = static_cast<uint8_t>(std::clamp(u, 0, 255));
            uvRow[x * 2 + 1] = static_cast<uint8_t>(std::clamp(v, 0, 255));
        }
    }
}

/// Append a 4-byte Annex-B start code (0x00000001) to a buffer.
static void appendStartCode(std::vector<uint8_t>& buf) {
    buf.push_back(0x00);
    buf.push_back(0x00);
    buf.push_back(0x00);
    buf.push_back(0x01);
}

// ---------------------------------------------------------------------------
// Ctor / Dtor
// ---------------------------------------------------------------------------
VaapiEncoder::VaapiEncoder() = default;

VaapiEncoder::~VaapiEncoder() {
    destroy();
}

// ---------------------------------------------------------------------------
// initialize
// ---------------------------------------------------------------------------
bool VaapiEncoder::initialize(int width, int height, int fps, int bitrateMbps)
{
    if (m_initialized) destroy();

    m_width       = width;
    m_height      = height;
    m_fps         = fps;
    m_bitrateMbps = bitrateMbps;

    // --- 1. Open DRM render node ---
    const char* drmDevice = "/dev/dri/renderD128";
    m_drmFd = open(drmDevice, O_RDWR);
    if (m_drmFd < 0) {
        printf("[VA-API] Cannot open %s\n", drmDevice);
        return false;
    }

    // --- 2. Get VA display ---
    m_vaDisplay = vaGetDisplayDRM(m_drmFd);
    if (!m_vaDisplay) {
        printf("[VA-API] vaGetDisplayDRM failed\n");
        destroy();
        return false;
    }

    int majorVer = 0, minorVer = 0;
    VAStatus st = vaInitialize(m_vaDisplay, &majorVer, &minorVer);
    if (st != VA_STATUS_SUCCESS) {
        printf("[VA-API] vaInitialize failed: %s\n", vaErrorStr(st));
        destroy();
        return false;
    }
    printf("[VA-API] VA-API %d.%d initialized\n", majorVer, minorVer);

    // --- 3. Check for HEVC encode support ---
    int numProfiles = vaMaxNumProfiles(m_vaDisplay);
    std::vector<VAProfile> profiles(numProfiles);
    vaQueryConfigProfiles(m_vaDisplay, profiles.data(), &numProfiles);

    bool hasHEVCMain = false;
    for (int i = 0; i < numProfiles; ++i) {
        if (profiles[i] == VAProfileHEVCMain) {
            hasHEVCMain = true;
            break;
        }
    }
    if (!hasHEVCMain) {
        printf("[VA-API] HEVCMain profile not supported\n");
        destroy();
        return false;
    }

    // Check entrypoints for encode
    int numEntrypoints = vaMaxNumEntrypoints(m_vaDisplay);
    std::vector<VAEntrypoint> entrypoints(numEntrypoints);
    vaQueryConfigEntrypoints(m_vaDisplay, VAProfileHEVCMain,
                             entrypoints.data(), &numEntrypoints);

    bool hasEncSlice = false;
    for (int i = 0; i < numEntrypoints; ++i) {
        if (entrypoints[i] == VAEntrypointEncSlice) {
            hasEncSlice = true;
            break;
        }
    }
    if (!hasEncSlice) {
        printf("[VA-API] HEVC EncSlice entrypoint not supported\n");
        destroy();
        return false;
    }

    // --- 4. Create config ---
    VAConfigAttrib attrib = {};
    attrib.type = VAConfigAttribRateControl;
    vaGetConfigAttributes(m_vaDisplay, VAProfileHEVCMain,
                          VAEntrypointEncSlice, &attrib, 1);

    // Prefer VBR, fall back to CBR
    uint32_t rcMode = VA_RC_VBR;
    if (!(attrib.value & VA_RC_VBR)) {
        if (attrib.value & VA_RC_CBR) {
            rcMode = VA_RC_CBR;
        } else {
            printf("[VA-API] Neither VBR nor CBR rate control supported\n");
            destroy();
            return false;
        }
    }

    VAConfigAttrib configAttribs[1];
    configAttribs[0].type  = VAConfigAttribRateControl;
    configAttribs[0].value = rcMode;

    st = vaCreateConfig(m_vaDisplay, VAProfileHEVCMain, VAEntrypointEncSlice,
                        configAttribs, 1, &m_vaConfig);
    if (st != VA_STATUS_SUCCESS) {
        printf("[VA-API] vaCreateConfig failed: %s\n", vaErrorStr(st));
        destroy();
        return false;
    }

    // --- 5. Create surfaces ---
    // Double-buffered source surfaces (NV12): upload to surface[cur] while
    // GPU encodes from surface[prev], eliminating vaSyncSurface stall.
    VASurfaceAttrib surfAttrib = {};
    surfAttrib.type            = VASurfaceAttribPixelFormat;
    surfAttrib.flags           = VA_SURFACE_ATTRIB_SETTABLE;
    surfAttrib.value.type      = VAGenericValueTypeInteger;
    surfAttrib.value.value.i   = VA_FOURCC_NV12;

    st = vaCreateSurfaces(m_vaDisplay, VA_RT_FORMAT_YUV420,
                          width, height, m_srcSurfaces, kNumBuffers,
                          &surfAttrib, 1);
    if (st != VA_STATUS_SUCCESS) {
        printf("[VA-API] vaCreateSurfaces (src) failed: %s\n", vaErrorStr(st));
        destroy();
        return false;
    }

    // Reconstructed surface (reference, required by encoder)
    st = vaCreateSurfaces(m_vaDisplay, VA_RT_FORMAT_YUV420,
                          width, height, &m_recSurface, 1,
                          &surfAttrib, 1);
    if (st != VA_STATUS_SUCCESS) {
        printf("[VA-API] vaCreateSurfaces (rec) failed: %s\n", vaErrorStr(st));
        destroy();
        return false;
    }

    // --- 6. Create context ---
    // All source surfaces + rec surface must be in the context
    VASurfaceID allSurfaces[kNumBuffers + 1];
    for (int i = 0; i < kNumBuffers; ++i) allSurfaces[i] = m_srcSurfaces[i];
    allSurfaces[kNumBuffers] = m_recSurface;
    st = vaCreateContext(m_vaDisplay, m_vaConfig,
                         width, height, VA_PROGRESSIVE,
                         allSurfaces, kNumBuffers + 1, &m_vaContext);
    if (st != VA_STATUS_SUCCESS) {
        printf("[VA-API] vaCreateContext failed: %s\n", vaErrorStr(st));
        destroy();
        return false;
    }

    // --- 7. Create double-buffered coded buffers ---
    // Size: generous upper bound for one intra frame
    int codedBufSize = width * height * 2;
    for (int i = 0; i < kNumBuffers; ++i) {
        st = vaCreateBuffer(m_vaDisplay, m_vaContext,
                            VAEncCodedBufferType, codedBufSize, 1,
                            nullptr, &m_codedBufs[i]);
        if (st != VA_STATUS_SUCCESS) {
            printf("[VA-API] vaCreateBuffer (coded %d) failed: %s\n", i, vaErrorStr(st));
            destroy();
            return false;
        }
    }
    m_curBuf = 0;
    m_prevPending = false;

    // --- 8. Build sequence parameters ---
    memset(&m_seqParam, 0, sizeof(m_seqParam));
    m_seqParam.general_profile_idc       = 1;  // Main profile
    m_seqParam.general_level_idc         = 120; // Level 4.0
    m_seqParam.general_tier_flag         = 0;   // Main tier
    m_seqParam.intra_period              = 1;   // All-intra (every frame IDR)
    m_seqParam.intra_idr_period          = 1;
    m_seqParam.ip_period                 = 1;   // No B-frames
    m_seqParam.bits_per_second           = static_cast<uint32_t>(bitrateMbps) * 1'000'000u;
    m_seqParam.pic_width_in_luma_samples  = static_cast<uint16_t>(width);
    m_seqParam.pic_height_in_luma_samples = static_cast<uint16_t>(height);

    // Coding tree block size (log2 - 3)
    m_seqParam.log2_min_luma_coding_block_size_minus3   = 0;  // min CU = 8
    m_seqParam.log2_diff_max_min_luma_coding_block_size = 2;  // max CU = 32
    m_seqParam.log2_min_transform_block_size_minus2     = 0;  // min TU = 4
    m_seqParam.log2_diff_max_min_transform_block_size   = 3;  // max TU = 32
    m_seqParam.max_transform_hierarchy_depth_inter      = 0;
    m_seqParam.max_transform_hierarchy_depth_intra      = 2;

    // VUI parameters for timing
    m_seqParam.vui_parameters_present_flag              = 1;
    m_seqParam.vui_fields.bits.vui_timing_info_present_flag = 1;
    m_seqParam.vui_num_units_in_tick = 1;
    m_seqParam.vui_time_scale        = static_cast<uint32_t>(fps * 2);

    m_initialized = true;
    m_frameIndex  = 0;

    // Check if driver supports packed headers (for manual VPS/SPS/PPS insertion)
    VAConfigAttrib packedAttrib = {};
    packedAttrib.type = VAConfigAttribEncPackedHeaders;
    vaGetConfigAttributes(m_vaDisplay, VAProfileHEVCMain,
                          VAEntrypointEncSlice, &packedAttrib, 1);
    if (packedAttrib.value & VA_ENC_PACKED_HEADER_SEQUENCE) {
        printf("[VA-API] Driver supports packed headers — parameter sets will be included\n");
    } else {
        printf("[VA-API] Driver handles parameter sets automatically\n");
    }

    printf("[VA-API] Initialized: %dx%d @ %dfps, %d Mbps, HEVC Main, all-intra\n",
           width, height, fps, bitrateMbps);
    return true;
}

// ---------------------------------------------------------------------------
// uploadFrame
// ---------------------------------------------------------------------------
bool VaapiEncoder::uploadFrame(const uint8_t* pixelData, int width,
                               int height, int stride)
{
    VAImage vaImage = {};
    VAStatus st = vaDeriveImage(m_vaDisplay, m_srcSurfaces[m_curBuf], &vaImage);
    if (st != VA_STATUS_SUCCESS) {
        printf("[VA-API] vaDeriveImage failed: %s\n", vaErrorStr(st));
        return false;
    }

    void* mapped = nullptr;
    st = vaMapBuffer(m_vaDisplay, vaImage.buf, &mapped);
    if (st != VA_STATUS_SUCCESS) {
        printf("[VA-API] vaMapBuffer failed: %s\n", vaErrorStr(st));
        vaDestroyImage(m_vaDisplay, vaImage.image_id);
        return false;
    }

    auto* dst = static_cast<uint8_t*>(mapped);

    // NV12: Y plane at offset[0], UV plane at offset[1]
    uint8_t* yPlane  = dst + vaImage.offsets[0];
    uint8_t* uvPlane = dst + vaImage.offsets[1];
    int yStride  = static_cast<int>(vaImage.pitches[0]);
    int uvStride = static_cast<int>(vaImage.pitches[1]);

    bgraToNV12(pixelData, width, height, stride,
               yPlane, yStride, uvPlane, uvStride);

    vaUnmapBuffer(m_vaDisplay, vaImage.buf);
    vaDestroyImage(m_vaDisplay, vaImage.image_id);
    return true;
}

// ---------------------------------------------------------------------------
// executeEncode
// ---------------------------------------------------------------------------
bool VaapiEncoder::executeEncode(uint64_t timestampNs)
{
    VAStatus st;
    std::vector<VABufferID> buffers;

    // --- Sequence parameter buffer ---
    {
        VABufferID buf = VA_INVALID_ID;
        st = vaCreateBuffer(m_vaDisplay, m_vaContext,
                            VAEncSequenceParameterBufferType,
                            sizeof(m_seqParam), 1, &m_seqParam, &buf);
        if (st != VA_STATUS_SUCCESS) {
            printf("[VA-API] create seq param buf failed: %s\n", vaErrorStr(st));
            return false;
        }
        buffers.push_back(buf);
    }

    // --- Picture parameter buffer ---
    VAEncPictureParameterBufferHEVC picParam = {};
    {
        picParam.decoded_curr_pic.picture_id = m_recSurface;
        picParam.decoded_curr_pic.pic_order_cnt = 0;  // All-intra, always 0

        // Mark all reference pictures as invalid (no references for IDR)
        for (auto& ref : picParam.reference_frames) {
            ref.picture_id = VA_INVALID_SURFACE;
            ref.flags      = VA_PICTURE_HEVC_INVALID;
        }

        picParam.coded_buf          = m_codedBuf;
        picParam.pic_fields.bits.coding_type     = 1;  // I-frame
        picParam.pic_fields.bits.idr_pic_flag    = 1;  // IDR
        picParam.pic_fields.bits.reference_pic_flag = 0; // not used as reference (all-intra)

        picParam.collocated_ref_pic_index = 0xFF;  // invalid
        picParam.pic_init_qp             = 26;     // base QP

        // Log2 parallel merge level
        picParam.log2_parallel_merge_level_minus2 = 0;

        VABufferID buf = VA_INVALID_ID;
        st = vaCreateBuffer(m_vaDisplay, m_vaContext,
                            VAEncPictureParameterBufferType,
                            sizeof(picParam), 1, &picParam, &buf);
        if (st != VA_STATUS_SUCCESS) {
            printf("[VA-API] create pic param buf failed: %s\n", vaErrorStr(st));
            for (auto b : buffers) vaDestroyBuffer(m_vaDisplay, b);
            return false;
        }
        buffers.push_back(buf);
    }

    // --- Slice parameter buffer ---
    {
        VAEncSliceParameterBufferHEVC sliceParam = {};
        sliceParam.slice_segment_address = 0;

        // Number of CTUs in the frame
        int ctbSize = 32; // from our log2 settings: 8 << 2 = 32
        int widthInCtb  = (m_width + ctbSize - 1) / ctbSize;
        int heightInCtb = (m_height + ctbSize - 1) / ctbSize;
        sliceParam.num_ctu_in_slice = static_cast<uint32_t>(widthInCtb * heightInCtb);

        sliceParam.slice_type = 2;  // I-slice
        sliceParam.slice_pic_parameter_set_id = 0;

        // No references
        for (auto& ref : sliceParam.ref_pic_list0) {
            ref.picture_id = VA_INVALID_SURFACE;
            ref.flags      = VA_PICTURE_HEVC_INVALID;
        }
        for (auto& ref : sliceParam.ref_pic_list1) {
            ref.picture_id = VA_INVALID_SURFACE;
            ref.flags      = VA_PICTURE_HEVC_INVALID;
        }

        sliceParam.max_num_merge_cand       = 5;
        sliceParam.slice_qp_delta           = 0;
        sliceParam.slice_fields.bits.last_slice_of_pic = 1;

        VABufferID buf = VA_INVALID_ID;
        st = vaCreateBuffer(m_vaDisplay, m_vaContext,
                            VAEncSliceParameterBufferType,
                            sizeof(sliceParam), 1, &sliceParam, &buf);
        if (st != VA_STATUS_SUCCESS) {
            printf("[VA-API] create slice param buf failed: %s\n", vaErrorStr(st));
            for (auto b : buffers) vaDestroyBuffer(m_vaDisplay, b);
            return false;
        }
        buffers.push_back(buf);
    }

    // --- Rate control parameter buffer ---
    {
        VAEncMiscParameterBuffer* miscBuf = nullptr;
        VABufferID buf = VA_INVALID_ID;
        st = vaCreateBuffer(m_vaDisplay, m_vaContext,
                            VAEncMiscParameterBufferType,
                            sizeof(VAEncMiscParameterBuffer) +
                            sizeof(VAEncMiscParameterRateControl),
                            1, nullptr, &buf);
        if (st != VA_STATUS_SUCCESS) {
            printf("[VA-API] create RC misc buf failed: %s\n", vaErrorStr(st));
            for (auto b : buffers) vaDestroyBuffer(m_vaDisplay, b);
            return false;
        }

        vaMapBuffer(m_vaDisplay, buf, reinterpret_cast<void**>(&miscBuf));
        miscBuf->type = VAEncMiscParameterTypeRateControl;

        auto* rc = reinterpret_cast<VAEncMiscParameterRateControl*>(miscBuf->data);
        memset(rc, 0, sizeof(*rc));
        rc->bits_per_second    = static_cast<uint32_t>(m_bitrateMbps) * 1'000'000u;
        rc->target_percentage  = 80;   // VBR target (80% of max)
        rc->window_size        = 1000; // 1 second window
        rc->initial_qp         = 26;
        rc->min_qp             = 1;
        rc->basic_unit_size    = 0;
        vaUnmapBuffer(m_vaDisplay, buf);

        buffers.push_back(buf);
    }

    // --- Frame rate parameter ---
    {
        VAEncMiscParameterBuffer* miscBuf = nullptr;
        VABufferID buf = VA_INVALID_ID;
        st = vaCreateBuffer(m_vaDisplay, m_vaContext,
                            VAEncMiscParameterBufferType,
                            sizeof(VAEncMiscParameterBuffer) +
                            sizeof(VAEncMiscParameterFrameRate),
                            1, nullptr, &buf);
        if (st == VA_STATUS_SUCCESS) {
            vaMapBuffer(m_vaDisplay, buf, reinterpret_cast<void**>(&miscBuf));
            miscBuf->type = VAEncMiscParameterTypeFrameRate;

            auto* fr = reinterpret_cast<VAEncMiscParameterFrameRate*>(miscBuf->data);
            memset(fr, 0, sizeof(*fr));
            fr->framerate = static_cast<uint32_t>(m_fps);  // fps / 1
            vaUnmapBuffer(m_vaDisplay, buf);

            buffers.push_back(buf);
        }
    }

    // --- Pipeline: sync+readout PREVIOUS frame while we submit CURRENT ---
    // This overlaps GPU encode of frame N-1 with CPU upload of frame N,
    // eliminating the vaSyncSurface stall from the critical path.
    int prevBuf = 1 - m_curBuf;

    if (m_prevPending) {
        // Wait for previous frame's encode to finish
        st = vaSyncSurface(m_vaDisplay, m_srcSurfaces[prevBuf]);
        if (st != VA_STATUS_SUCCESS) {
            printf("[VA-API] vaSyncSurface (prev) failed: %s\n", vaErrorStr(st));
            // Non-fatal: continue to submit current frame
        } else {
            // Read out previous frame's bitstream
            readoutBitstream(m_codedBufs[prevBuf], m_prevTimestampNs);
        }
        m_prevPending = false;
    }

    // --- Begin picture / render / end picture (current frame) ---
    picParam.coded_buf = m_codedBufs[m_curBuf];

    st = vaBeginPicture(m_vaDisplay, m_vaContext, m_srcSurfaces[m_curBuf]);
    if (st != VA_STATUS_SUCCESS) {
        printf("[VA-API] vaBeginPicture failed: %s\n", vaErrorStr(st));
        for (auto b : buffers) vaDestroyBuffer(m_vaDisplay, b);
        return false;
    }

    st = vaRenderPicture(m_vaDisplay, m_vaContext,
                         buffers.data(), static_cast<int>(buffers.size()));
    if (st != VA_STATUS_SUCCESS) {
        printf("[VA-API] vaRenderPicture failed: %s\n", vaErrorStr(st));
        vaEndPicture(m_vaDisplay, m_vaContext);
        return false;
    }

    st = vaEndPicture(m_vaDisplay, m_vaContext);
    if (st != VA_STATUS_SUCCESS) {
        printf("[VA-API] vaEndPicture failed: %s\n", vaErrorStr(st));
        return false;
    }

    // Mark current buffer as pending, save timestamp for readout later
    m_prevPending = true;
    m_prevTimestampNs = timestampNs;

    // Swap buffer index for next frame
    m_curBuf = 1 - m_curBuf;

    m_frameIndex++;
    return true;
}

// ---------------------------------------------------------------------------
// readoutBitstream — extract encoded data from a coded buffer and deliver
// ---------------------------------------------------------------------------
void VaapiEncoder::readoutBitstream(VABufferID codedBuf, uint64_t timestampNs)
{
    VACodedBufferSegment* segment = nullptr;
    VAStatus st = vaMapBuffer(m_vaDisplay, codedBuf, reinterpret_cast<void**>(&segment));
    if (st != VA_STATUS_SUCCESS) {
        printf("[VA-API] vaMapBuffer (coded) failed: %s\n", vaErrorStr(st));
        return;
    }

    std::vector<uint8_t> output;
    bool needParamSets = true;

    while (segment) {
        auto* data = static_cast<const uint8_t*>(segment->buf);
        size_t size = segment->size;

        // Check if data already contains VPS (NAL type 32)
        if (size >= 5 && data[0] == 0x00 && data[1] == 0x00 &&
            data[2] == 0x00 && data[3] == 0x01) {
            uint8_t nalType = (data[4] >> 1) & 0x3F;
            if (nalType == 32) needParamSets = false;
        }

        output.insert(output.end(), data, data + size);
        segment = reinterpret_cast<VACodedBufferSegment*>(segment->next);
    }

    vaUnmapBuffer(m_vaDisplay, codedBuf);

    if (needParamSets && !m_parameterSets.empty()) {
        std::vector<uint8_t> combined;
        combined.reserve(m_parameterSets.size() + output.size());
        combined.insert(combined.end(), m_parameterSets.begin(), m_parameterSets.end());
        combined.insert(combined.end(), output.begin(), output.end());
        output = std::move(combined);
    }

    if (m_parameterSets.empty() && !needParamSets) {
        buildParameterSets(output);
    }

    if (!output.empty()) {
        deliverOutput(output.data(), output.size(), timestampNs, true /* always IDR */);
    }
}

// ---------------------------------------------------------------------------
// buildParameterSets — extract VPS/SPS/PPS NAL units from encoded output
// ---------------------------------------------------------------------------
bool VaapiEncoder::buildParameterSets(const std::vector<uint8_t>& encodedOutput)
{
    // Scan through the Annex-B stream and extract VPS (32), SPS (33), PPS (34)
    m_parameterSets.clear();
    size_t pos = 0;
    while (pos + 4 < encodedOutput.size()) {
        // Find start code
        if (encodedOutput[pos] != 0x00 || encodedOutput[pos + 1] != 0x00 ||
            encodedOutput[pos + 2] != 0x00 || encodedOutput[pos + 3] != 0x01) {
            ++pos;
            continue;
        }
        // Find next start code to determine NAL unit size
        size_t nalStart = pos;
        size_t nalHeaderPos = pos + 4;
        if (nalHeaderPos >= encodedOutput.size()) break;

        uint8_t nalType = (encodedOutput[nalHeaderPos] >> 1) & 0x3F;

        // Find next start code
        size_t nextStart = nalHeaderPos + 1;
        while (nextStart + 3 < encodedOutput.size()) {
            if (encodedOutput[nextStart] == 0x00 && encodedOutput[nextStart + 1] == 0x00 &&
                encodedOutput[nextStart + 2] == 0x00 && encodedOutput[nextStart + 3] == 0x01) {
                break;
            }
            ++nextStart;
        }
        if (nextStart + 3 >= encodedOutput.size()) {
            nextStart = encodedOutput.size();
        }

        // VPS=32, SPS=33, PPS=34
        if (nalType >= 32 && nalType <= 34) {
            m_parameterSets.insert(m_parameterSets.end(),
                                   encodedOutput.begin() + static_cast<long>(nalStart),
                                   encodedOutput.begin() + static_cast<long>(nextStart));
        }

        pos = (nextStart < encodedOutput.size()) ? nextStart : encodedOutput.size();
    }

    if (!m_parameterSets.empty()) {
        printf("[VA-API] Cached %zu bytes of VPS/SPS/PPS parameter sets\n",
               m_parameterSets.size());
    }
    return !m_parameterSets.empty();
}

// ---------------------------------------------------------------------------
// encode
// ---------------------------------------------------------------------------
bool VaapiEncoder::encode(const uint8_t* pixelData, int width, int height,
                          int stride, uint64_t timestampNs)
{
    if (!m_initialized || !pixelData) return false;

    // Upload BGRA → NV12 into VA surface
    if (!uploadFrame(pixelData, width, height, stride)) {
        return false;
    }

    // Execute encode
    return executeEncode(timestampNs);
}

// ---------------------------------------------------------------------------
// updateSettings
// ---------------------------------------------------------------------------
void VaapiEncoder::updateSettings(int bitrateMbps, float quality, bool gamingBoost)
{
    if (!m_initialized) return;

    // Apply gaming boost overrides
    if (gamingBoost) {
        bitrateMbps = Config::GAMING_BOOST_BITRATE;
        quality     = Config::GAMING_BOOST_QUALITY;
    }

    // Clamp
    bitrateMbps = std::clamp(bitrateMbps,
                             Config::MIN_BITRATE_MBPS,
                             Config::MAX_BITRATE_MBPS);
    m_bitrateMbps = bitrateMbps;

    // Update sequence parameter for next frame (rate control is applied
    // per-frame through misc parameter buffers in executeEncode)
    m_seqParam.bits_per_second = static_cast<uint32_t>(bitrateMbps) * 1'000'000u;

    printf("[VA-API] Settings updated: %d Mbps, quality=%.2f, gaming=%d\n",
           bitrateMbps, quality, gamingBoost);
}

// ---------------------------------------------------------------------------
// flush
// ---------------------------------------------------------------------------
void VaapiEncoder::flush()
{
    if (!m_initialized) return;

    // Drain the pending pipelined frame
    if (m_prevPending) {
        int prevBuf = 1 - m_curBuf;
        VAStatus st = vaSyncSurface(m_vaDisplay, m_srcSurfaces[prevBuf]);
        if (st == VA_STATUS_SUCCESS) {
            readoutBitstream(m_codedBufs[prevBuf], m_prevTimestampNs);
        }
        m_prevPending = false;
    }
}

// ---------------------------------------------------------------------------
// destroy
// ---------------------------------------------------------------------------
void VaapiEncoder::destroy()
{
    if (m_vaDisplay) {
        for (int i = 0; i < kNumBuffers; ++i) {
            if (m_codedBufs[i] != VA_INVALID_ID) {
                vaDestroyBuffer(m_vaDisplay, m_codedBufs[i]);
                m_codedBufs[i] = VA_INVALID_ID;
            }
        }
        if (m_vaContext != VA_INVALID_ID) {
            vaDestroyContext(m_vaDisplay, m_vaContext);
            m_vaContext = VA_INVALID_ID;
        }
        // Destroy double-buffered source surfaces
        for (int i = 0; i < kNumBuffers; ++i) {
            if (m_srcSurfaces[i] != VA_INVALID_SURFACE) {
                vaDestroySurfaces(m_vaDisplay, &m_srcSurfaces[i], 1);
                m_srcSurfaces[i] = VA_INVALID_SURFACE;
            }
        }
        if (m_recSurface != VA_INVALID_SURFACE) {
            vaDestroySurfaces(m_vaDisplay, &m_recSurface, 1);
            m_recSurface = VA_INVALID_SURFACE;
        }
        if (m_vaConfig != VA_INVALID_ID) {
            vaDestroyConfig(m_vaDisplay, m_vaConfig);
            m_vaConfig = VA_INVALID_ID;
        }
        vaTerminate(m_vaDisplay);
        m_vaDisplay = nullptr;
    }

    if (m_drmFd >= 0) {
        close(m_drmFd);
        m_drmFd = -1;
    }

    m_initialized = false;
    m_parameterSets.clear();
}

#endif // HAS_VAAPI
