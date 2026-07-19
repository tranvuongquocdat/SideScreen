package com.sidescreen.app

import android.media.MediaCodecList
import android.media.MediaFormat

/**
 * One-shot decoder capability probe. AVC-only devices drive the H.264
 * wire-protocol negotiation (the Mac encodes H.264 instead of HEVC).
 *
 * "Has HEVC" means the device has a *usable hardware* HEVC decoder — not merely
 * any decoder that advertises the type. Two classes of device are deliberately
 * routed to H.264 instead:
 *
 *  - **Software-only HEVC** (e.g. Onyx Boox Nova Air C, whose vendor
 *    media_codecs.xml disables HW HEVC): the Google software decoder
 *    (c2.android.hevc / OMX.google.hevc) is far too slow for real-time mirroring.
 *
 *  - **Broken vendor HW HEVC**: Spreadtrum/Unisoc (OMX.sprd.hevc, c2.sprd.*)
 *    advertise a HW HEVC decoder that configures and starts successfully but
 *    never renders decoded frames to the output Surface — the SurfaceView stays
 *    empty and the user sees a black screen (e.g. Yuho Tab 10, SC9863A + PowerVR).
 *
 * Both classes have a working hardware H.264 decoder, so H.264 is the reliable
 * path for them.
 */
object CodecCapabilities {
    /** Decoder-name prefixes whose HEVC implementation is unusable for surface output. */
    private val BROKEN_HEVC_HW_PREFIXES = listOf("omx.sprd.", "c2.sprd.")

    val hasHevcDecoder: Boolean by lazy {
        try {
            MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.any { info ->
                if (info.isEncoder) return@any false
                val handlesHevc =
                    info.supportedTypes.any { it.equals(MediaFormat.MIMETYPE_VIDEO_HEVC, ignoreCase = true) }
                if (!handlesHevc) return@any false

                val name = info.name.lowercase()
                // Same hardware/software split VideoDecoder.findBestDecoder uses.
                val isSoftware = name.startsWith("c2.android.") || name.startsWith("omx.google.")
                val isBrokenHardware = BROKEN_HEVC_HW_PREFIXES.any { name.startsWith(it) }
                !isSoftware && !isBrokenHardware
            }
        } catch (_: Exception) {
            true // fail open: assume HEVC, preserving legacy behavior
        }
    }

    /** Mime the client will ask the Mac to stream: HEVC when usable, else AVC. */
    val streamMime: String
        get() = if (hasHevcDecoder) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC

    private val maxDecodeSizeCache = HashMap<String, Pair<Int, Int>?>()

    /**
     * Upper decode bounds (width × height) of the largest usable *hardware*
     * decoder for [mime] — the software fallback is too slow for real-time
     * mirroring to count as a ceiling. Null when nothing usable exists or the
     * probe fails (legacy behavior: no limit advertised to the Mac).
     * Cached per mime: enumerating MediaCodecList is not cheap and the answer
     * never changes at runtime (same reason hasHevcDecoder is lazy).
     */
    fun maxDecodeSize(mime: String): Pair<Int, Int>? =
        synchronized(maxDecodeSizeCache) {
            maxDecodeSizeCache.getOrPut(mime.lowercase()) { probeMaxDecodeSize(mime) }
        }

    private fun probeMaxDecodeSize(mime: String): Pair<Int, Int>? =
        try {
            MediaCodecList(MediaCodecList.ALL_CODECS)
                .codecInfos
                .asSequence()
                .filter { !it.isEncoder }
                .filter { info -> info.supportedTypes.any { it.equals(mime, ignoreCase = true) } }
                .filter { info ->
                    val name = info.name.lowercase()
                    val isSoftware = name.startsWith("c2.android.") || name.startsWith("omx.google.")
                    val isBrokenHevc =
                        mime.equals(MediaFormat.MIMETYPE_VIDEO_HEVC, ignoreCase = true) &&
                            BROKEN_HEVC_HW_PREFIXES.any { name.startsWith(it) }
                    !isSoftware && !isBrokenHevc
                }
                .mapNotNull { info ->
                    val videoCaps =
                        try {
                            info.getCapabilitiesForType(mime).videoCapabilities
                        } catch (_: Exception) {
                            null
                        }
                    videoCaps?.let { it.supportedWidths.upper to it.supportedHeights.upper }
                }
                .maxByOrNull { (w, h) -> w.toLong() * h.toLong() }
        } catch (_: Exception) {
            null
        }
}
