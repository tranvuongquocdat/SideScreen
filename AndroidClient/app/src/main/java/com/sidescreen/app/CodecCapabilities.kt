package com.sidescreen.app

import android.media.MediaCodecInfo
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

    /**
     * Usable *hardware* decoder for [mime]: not an encoder, not the (too slow
     * for real-time mirroring) Google software implementation, and for HEVC
     * not one of the vendor implementations that never render to a Surface.
     * Shared by [hasHevcDecoder] and [nominalMaxDecodeSize] so the classification
     * cannot drift between them. Same hardware/software split
     * VideoDecoder.findBestDecoder uses.
     */
    private fun isUsableHardwareDecoder(
        info: MediaCodecInfo,
        mime: String,
    ): Boolean {
        if (info.isEncoder) return false
        if (info.supportedTypes.none { it.equals(mime, ignoreCase = true) }) return false
        val name = info.name.lowercase()
        val isSoftware = name.startsWith("c2.android.") || name.startsWith("omx.google.")
        val isBrokenHevc =
            mime.equals(MediaFormat.MIMETYPE_VIDEO_HEVC, ignoreCase = true) &&
                BROKEN_HEVC_HW_PREFIXES.any { name.startsWith(it) }
        return !isSoftware && !isBrokenHevc
    }

    val hasHevcDecoder: Boolean by lazy {
        try {
            MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.any {
                isUsableHardwareDecoder(it, MediaFormat.MIMETYPE_VIDEO_HEVC)
            }
        } catch (_: Exception) {
            true // fail open: assume HEVC, preserving legacy behavior
        }
    }

    /**
     * How much larger (by area) the H.264 picture must be before it is worth its higher bitrate.
     * Below this the two codecs are treated as equivalent and HEVC keeps its bandwidth edge.
     */
    private const val AVC_PREFERENCE_AREA_GAIN = 1.2

    /**
     * Mime the client will ask the Mac to stream for a panel of [panelWidth]x[panelHeight]:
     * HEVC unless the device has no usable HEVC decoder, or its H.264 decoder sustains a
     * noticeably larger picture at [REFERENCE_FPS]. Budget tablets commonly pair a Level 4 HEVC
     * decoder (about 1080p30) with a far higher H.264 one; streaming HEVC there means a blurry
     * upscale of a quarter-size picture (issue #78). A non-positive panel size falls back to
     * decoder availability alone.
     */
    fun preferredStreamMime(
        panelWidth: Int,
        panelHeight: Int,
    ): String {
        if (!hasHevcDecoder) return MediaFormat.MIMETYPE_VIDEO_AVC
        val hevc = maxStreamSize(MediaFormat.MIMETYPE_VIDEO_HEVC, panelWidth, panelHeight, REFERENCE_FPS)
        val avc = maxStreamSize(MediaFormat.MIMETYPE_VIDEO_AVC, panelWidth, panelHeight, REFERENCE_FPS)
        if (hevc == null || avc == null) return MediaFormat.MIMETYPE_VIDEO_HEVC
        val gain = area(avc) / area(hevc)
        return if (gain >= AVC_PREFERENCE_AREA_GAIN) MediaFormat.MIMETYPE_VIDEO_AVC else MediaFormat.MIMETYPE_VIDEO_HEVC
    }

    private fun area(size: Pair<Int, Int>): Double = size.first.toDouble() * size.second.toDouble()

    private val nominalSizeCache = HashMap<String, Pair<Int, Int>?>()

    /**
     * The `size` limit the largest usable *hardware* decoder for [mime] advertises. Null when
     * nothing usable exists or the probe fails (legacy behavior: advertise no limit to the Mac).
     * Cached per mime: enumerating MediaCodecList is not cheap and the answer never changes at
     * runtime (same reason hasHevcDecoder is lazy).
     *
     * Nominal, not achievable. Vendor decoders routinely advertise a `size` far above what their
     * `blocks-per-second` budget can sustain, and configuring above that budget succeeds and then
     * silently never outputs a frame. Prefer [maxStreamSize] for anything the Mac will encode.
     */
    fun nominalMaxDecodeSize(mime: String): Pair<Int, Int>? =
        synchronized(nominalSizeCache) {
            nominalSizeCache.getOrPut(mime.lowercase()) { probeNominalSize(mime) }
        }

    private fun probeNominalSize(mime: String): Pair<Int, Int>? =
        bestVideoCapabilities(mime)?.let { it.supportedWidths.upper to it.supportedHeights.upper }

    private val capsCache = HashMap<String, MediaCodecInfo.VideoCapabilities?>()

    /**
     * Video capabilities of the largest usable hardware decoder for [mime]. Cached: a connection
     * now asks several times (per codec, per table rate) and MediaCodecList enumeration is slow.
     */
    private fun bestVideoCapabilities(mime: String): MediaCodecInfo.VideoCapabilities? =
        synchronized(capsCache) {
            capsCache.getOrPut(mime.lowercase()) { enumerateBestVideoCapabilities(mime) }
        }

    private fun enumerateBestVideoCapabilities(mime: String): MediaCodecInfo.VideoCapabilities? =
        try {
            MediaCodecList(MediaCodecList.ALL_CODECS)
                .codecInfos
                .asSequence()
                .filter { isUsableHardwareDecoder(it, mime) }
                .mapNotNull { info ->
                    try {
                        info.getCapabilitiesForType(mime).videoCapabilities
                    } catch (_: Exception) {
                        null
                    }
                }.maxByOrNull { it.supportedWidths.upper.toLong() * it.supportedHeights.upper.toLong() }
        } catch (_: Exception) {
            null
        }

    private const val BLOCK_ALIGN = 16

    /**
     * Frame rate the advertised stream limit is measured at. The client cannot know the Mac's
     * frame-rate setting when it advertises (that arrives later), and measuring at the panel's
     * peak rate would shrink the picture on 120/144 Hz tablets that stream at the 60 Hz default.
     * The Mac scales the limit's area by 60/fps when it streams faster than this, so both sides
     * must agree on the number (see CodecLimits.scaleLimit on the Mac).
     */
    const val REFERENCE_FPS = 60

    /**
     * Frame rates the client measures [maxStreamSize] at for the type-14 limit table, in wire
     * order. The Mac picks the entry at or above its own frame rate, so a 30 Hz stream gets the
     * whole decode budget instead of the 60 Hz figure, and a 120 Hz stream gets a measured figure
     * instead of a guess scaled from a limit that may only have been the panel size (issue #78).
     * Must match CodecLimits.tableFps on the Mac.
     */
    val TABLE_FPS = intArrayOf(30, 60, 120)

    /**
     * [maxStreamSize] at every [TABLE_FPS] rate, in that order, or null when any rate cannot be
     * measured (the Mac then falls back to the single [REFERENCE_FPS] limit).
     */
    fun streamLimitTable(
        mime: String,
        panelWidth: Int,
        panelHeight: Int,
    ): List<Pair<Int, Int>>? = TABLE_FPS.map { maxStreamSize(mime, panelWidth, panelHeight, it) ?: return null }

    /**
     * The largest frame the Mac should ever encode for us: no larger than the panel can show, and
     * within what the decoder sustains at [fps]. Null when no usable decoder exists or the probe
     * fails, which leaves the legacy "advertise nothing" behavior in place.
     *
     * The panel is the upper bound because anything above it is downscaled on arrival anyway, so
     * spending decode budget there buys nothing. [MediaCodecInfo.VideoCapabilities.areSizeAndRateSupported]
     * is the check that consults `blocks-per-second`, which [nominalMaxDecodeSize] misses.
     */
    fun maxStreamSize(
        mime: String,
        panelWidth: Int,
        panelHeight: Int,
        fps: Int,
    ): Pair<Int, Int>? {
        if (panelWidth <= 0 || panelHeight <= 0) return null
        val caps = bestVideoCapabilities(mime) ?: return null
        val rate = fps.coerceAtLeast(1).toDouble()
        return try {
            fitStreamSize(
                panelWidth = panelWidth,
                panelHeight = panelHeight,
                maxWidth = caps.supportedWidths.upper,
                maxHeight = caps.supportedHeights.upper,
                widthAlignment = caps.widthAlignment,
                heightAlignment = caps.heightAlignment,
            ) { w, h ->
                try {
                    caps.areSizeAndRateSupported(w, h, rate)
                } catch (_: IllegalArgumentException) {
                    false
                }
            }
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Largest size for a panel of [panelWidth]x[panelHeight] that [supports] accepts, or null.
     *
     * The native panel size comes first, aligned only to what the decoder itself requires
     * ([widthAlignment]/[heightAlignment], usually 2). [supports] already counts macroblocks
     * rounded up, so a panel side that is not a multiple of 16 (1800, 1080) needs no padding
     * here. Flooring it to 16 instead made a 2880x1800 panel report 2880x1792, and the Mac then
     * encoded 2864x1792 and the client upscaled it back. When the native size is over budget,
     * shrinks stepwise on 16-aligned sizes, because the budget counts aligned macroblocks.
     */
    internal fun fitStreamSize(
        panelWidth: Int,
        panelHeight: Int,
        maxWidth: Int,
        maxHeight: Int,
        widthAlignment: Int,
        heightAlignment: Int,
        supports: (width: Int, height: Int) -> Boolean,
    ): Pair<Int, Int>? {
        if (panelWidth <= maxWidth && panelHeight <= maxHeight) {
            val nativeW = alignDown(panelWidth, widthAlignment)
            val nativeH = alignDown(panelHeight, heightAlignment)
            if (nativeW >= MIN_STREAM_SIDE && nativeH >= MIN_STREAM_SIDE && supports(nativeW, nativeH)) {
                return nativeW to nativeH
            }
        }

        var w = panelWidth.coerceAtMost(maxWidth)
        var h = panelHeight.coerceAtMost(maxHeight)
        val aspect = panelWidth.toDouble() / panelHeight.toDouble()

        repeat(40) {
            val alignedW = alignDown(w, BLOCK_ALIGN)
            val alignedH = alignDown(h, BLOCK_ALIGN)
            if (alignedW < MIN_STREAM_SIDE || alignedH < MIN_STREAM_SIDE) return null
            if (supports(alignedW, alignedH)) return alignedW to alignedH
            w = (w * 0.95).toInt()
            h = (w / aspect).toInt()
        }
        return null
    }

    private const val MIN_STREAM_SIDE = 256

    private fun alignDown(
        value: Int,
        alignment: Int,
    ): Int {
        val a = alignment.coerceAtLeast(1)
        return (value / a) * a
    }
}
