package com.sidescreen.app

import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.util.Log
import android.view.Display
import android.view.Surface
import java.util.concurrent.ConcurrentLinkedQueue

private fun diagLog(msg: String) = DiagLog.log("VD", msg)

class VideoDecoder(
    private val surface: Surface,
    private val display: Display? = null,
    initialWidth: Int = 1920,
    initialHeight: Int = 1200,
) {
    private var decoder: MediaCodec? = null
    private var decoderThread: HandlerThread? = null
    private var decoderHandler: Handler? = null

    private var frameCount = 0L
    private var droppedFrames = 0L
    private var staleOutputDrops = 0L
    private var lastStatsTime = System.currentTimeMillis()
    private var inputFrameCount = 0L
    private var outputFrameCount = 0L

    // Decoder pipeline latency (input enqueue -> output buffer available),
    // accumulated over ~60 frames then logged. High values indicate the codec
    // is queuing frames internally (compose/present can't keep up downstream),
    // which surfaces to the user as input lag on the captured display.
    private var latencySumNs: Long = 0
    private var latencySamples: Int = 0
    private var latencyMaxNs: Long = 0

    private val frameTimes = ArrayDeque<Long>(120)

    private val displayRefreshRate = display?.refreshRate ?: 60f

    private var currentWidth = initialWidth
    private var currentHeight = initialHeight

    @Volatile private var isRunning = false

    @Volatile private var needsKeyframe = true

    private var lastKeyframeRequestNs = 0L

    var onFrameRendered: ((Long) -> Unit)? = null
    var onFrameStats: ((fps: Double, variance: Double) -> Unit)? = null
    var onFrameDecoded: ((ByteArray) -> Unit)? = null
    var onKeyframeRequired: ((force: Boolean, reason: String) -> Unit)? = null

    // Available input buffer indices — fed by onInputBufferAvailable callback
    private val availableInputBuffers = ConcurrentLinkedQueue<Int>()

    init {
        setupDecoder()
    }

    fun updateResolution(
        width: Int,
        height: Int,
    ) {
        if (width != currentWidth || height != currentHeight) {
            currentWidth = width
            currentHeight = height
            release()
            setupDecoder()
            requestKeyframe("resolution changed", force = true)
        }
    }

    private fun setupDecoder() {
        decoderThread = HandlerThread("DecoderThread", Process.THREAD_PRIORITY_DISPLAY).also { it.start() }
        decoderHandler = Handler(decoderThread!!.looper)

        // Find a decoder that supports our resolution (prefer HW, fallback to SW)
        val decoderName = findBestDecoder(currentWidth, currentHeight)
        diagLog("setupDecoder: ${currentWidth}x$currentHeight, decoder=$decoderName")

        val codec =
            if (decoderName != null) {
                MediaCodec.createByCodecName(decoderName)
            } else {
                MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_HEVC)
            }

        val callback =
            object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(
                    codec: MediaCodec,
                    index: Int,
                ) {
                    availableInputBuffers.offer(index)
                }

                override fun onOutputBufferAvailable(
                    codec: MediaCodec,
                    index: Int,
                    info: MediaCodec.BufferInfo,
                ) {
                    handleOutputBuffer(codec, index, info)
                }

                override fun onError(
                    codec: MediaCodec,
                    e: MediaCodec.CodecException,
                ) {
                    diagLog("Codec error: ${e.diagnosticInfo}")
                    Log.e(TAG, "Codec error: ${e.diagnosticInfo}", e)
                    needsKeyframe = true
                    requestKeyframe("codec error", force = true)
                }

                override fun onOutputFormatChanged(
                    codec: MediaCodec,
                    format: MediaFormat,
                ) {
                    diagLog("Output format changed: $format")
                }
            }
        codec.setCallback(callback, decoderHandler)

        val format =
            MediaFormat.createVideoFormat(
                MediaFormat.MIMETYPE_VIDEO_HEVC,
                currentWidth,
                currentHeight,
            )

        var configured = false

        // Attempt 1: Full low-latency config
        try {
            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            format.setInteger(MediaFormat.KEY_PRIORITY, 0)
            format.setInteger(MediaFormat.KEY_OPERATING_RATE, displayRefreshRate.toInt())
            format.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            codec.configure(format, surface, null, 0)
            configured = true
            diagLog("Configured with full low-latency")
        } catch (e: Exception) {
            diagLog("Full low-latency config failed: ${e.message}")
            codec.reset()
            codec.setCallback(callback, decoderHandler)
        }

        // Attempt 2: Without KEY_LOW_LATENCY
        if (!configured) {
            try {
                val basicFormat =
                    MediaFormat.createVideoFormat(
                        MediaFormat.MIMETYPE_VIDEO_HEVC,
                        currentWidth,
                        currentHeight,
                    )
                basicFormat.setInteger(MediaFormat.KEY_PRIORITY, 0)
                basicFormat.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
                codec.configure(basicFormat, surface, null, 0)
                configured = true
                diagLog("Configured with basic format")
            } catch (e: Exception) {
                diagLog("Basic config failed: ${e.message}")
                codec.reset()
                codec.setCallback(callback, decoderHandler)
            }
        }

        // Attempt 3: Minimal config (just resolution)
        if (!configured) {
            try {
                val minimalFormat =
                    MediaFormat.createVideoFormat(
                        MediaFormat.MIMETYPE_VIDEO_HEVC,
                        currentWidth,
                        currentHeight,
                    )
                codec.configure(minimalFormat, surface, null, 0)
                diagLog("Configured with minimal format")
            } catch (e: Exception) {
                diagLog("All configure attempts failed: ${e.message}")
                Log.e(TAG, "All configure attempts failed", e)
                codec.release()
                decoderThread?.quitSafely()
                decoderThread = null
                decoderHandler = null
                throw e
            }
        }

        codec.setVideoScalingMode(MediaCodec.VIDEO_SCALING_MODE_SCALE_TO_FIT)
        needsKeyframe = true
        isRunning = true
        codec.start()
        decoder = codec
        diagLog(
            "Decoder started: ${currentWidth}x$currentHeight @ ${displayRefreshRate}Hz, " +
                "surface=$surface, valid=${surface.isValid}",
        )
    }

    /**
     * Find the best HEVC decoder for the given resolution.
     * Prefers hardware decoders, falls back to software if HW can't handle the resolution.
     * Returns codec name to use with MediaCodec.createByCodecName(), or null for default.
     */
    private fun findBestDecoder(
        width: Int,
        height: Int,
    ): String? {
        try {
            val codecList = MediaCodecList(MediaCodecList.ALL_CODECS)
            val targetRate = displayRefreshRate.toDouble().coerceAtLeast(30.0)
            var hwRateDecoder: String? = null
            var hwSizeDecoder: String? = null
            var swRateDecoder: String? = null
            var swSizeDecoder: String? = null

            for (info in codecList.codecInfos) {
                if (info.isEncoder) continue
                val caps =
                    try {
                        info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_HEVC)
                    } catch (_: Exception) {
                        continue
                    }

                val videoCaps = caps.videoCapabilities ?: continue
                val isHardware =
                    !info.name.startsWith("c2.android.") &&
                        !info.name.startsWith("OMX.google.")
                val supported = videoCaps.isSizeSupported(width, height)
                val rateSupported =
                    supported &&
                        try {
                            videoCaps.areSizeAndRateSupported(width, height, targetRate)
                        } catch (_: Exception) {
                            false
                        }

                diagLog(
                    "HEVC decoder '${info.name}': " +
                        "width=${videoCaps.supportedWidths}, " +
                        "height=${videoCaps.supportedHeights}, " +
                        "hw=$isHardware, supports ${width}x$height=$supported, " +
                        "supports @${"%.0f".format(targetRate)}fps=$rateSupported",
                )

                if (supported) {
                    if (isHardware && rateSupported && hwRateDecoder == null) {
                        hwRateDecoder = info.name
                    } else if (isHardware && hwSizeDecoder == null) {
                        hwSizeDecoder = info.name
                    } else if (!isHardware && rateSupported && swRateDecoder == null) {
                        swRateDecoder = info.name
                    } else if (!isHardware && swSizeDecoder == null) {
                        swSizeDecoder = info.name
                    }
                }
            }

            // Prefer hardware that advertises the target refresh rate, then any
            // hardware decoder for the size, then software as a last resort.
            val chosen = hwRateDecoder ?: hwSizeDecoder ?: swRateDecoder ?: swSizeDecoder
            if (chosen != null) {
                diagLog(
                    "Selected decoder: $chosen " +
                        "(rateSupported=${chosen == hwRateDecoder || chosen == swRateDecoder})",
                )
            } else {
                diagLog("No decoder supports ${width}x$height — will use default")
            }
            return chosen
        } catch (e: Exception) {
            diagLog("Decoder search failed: ${e.message}")
        }
        return null
    }

    fun decode(
        frameData: ByteArray,
        frameSize: Int = frameData.size,
        frameTimestamp: Long = System.nanoTime(),
        isKeyframe: Boolean = false,
    ) {
        if (!isRunning) {
            diagLog("decode called but isRunning=false")
            onFrameDecoded?.invoke(frameData)
            return
        }

        inputFrameCount++
        if (inputFrameCount == 1L) {
            val header =
                frameData
                    .take(minOf(16, frameSize))
                    .joinToString(" ") { String.format("%02x", it) }
            diagLog(
                "First frame: size=$frameSize, header=[$header], " +
                    "keyframe=$isKeyframe, surface=$surface, valid=${surface.isValid}",
            )
        }
        if (inputFrameCount % 60L == 0L) {
            diagLog(
                "Decode stats: input=$inputFrameCount, output=$outputFrameCount, " +
                    "dropped=$droppedFrames, availBufs=${availableInputBuffers.size}",
            )
        }

        val codec =
            decoder ?: run {
                diagLog("decoder is null in decode()")
                onFrameDecoded?.invoke(frameData)
                return
            }

        if (needsKeyframe && !isKeyframe) {
            dropFrame(
                frameData,
                isKeyframe,
                "waiting for keyframe",
                waitForKeyframe = true,
            )
            return
        }

        // Direct feed: grab an available input buffer and queue immediately.
        val index = availableInputBuffers.poll()
        if (index == null) {
            // Decoder input pool exhausted (typically a WiFi burst saturating
            // MediaCodec). Do NOT pause the pipeline — keep feeding so the
            // cursor tracks live. Reference state diverges briefly (cursor
            // trail visible), but a force-keyframe request bypasses every
            // layer's throttle and rebuilds the reference within ~100-200 ms,
            // which feels better than a 1-2 s freeze waiting on the next
            // throttled request to land.
            droppedFrames++
            if (droppedFrames <= 3L || droppedFrames % 60L == 0L) {
                diagLog("Dropping frame (no input buffer, dropped=$droppedFrames)")
            }
            requestKeyframe("no input buffer", force = true)
            onFrameDecoded?.invoke(frameData)
            return
        }

        queueFrame(codec, index, frameData, frameSize, frameTimestamp, isKeyframe)
    }

    private fun queueFrame(
        codec: MediaCodec,
        index: Int,
        frameData: ByteArray,
        frameSize: Int,
        frameTimestamp: Long,
        isKeyframe: Boolean,
    ) {
        try {
            val inputBuffer =
                codec.getInputBuffer(index)
                    ?: throw IllegalStateException("Input buffer $index is null")
            inputBuffer.clear()
            inputBuffer.put(frameData, 0, frameSize)
            codec.queueInputBuffer(index, 0, frameSize, frameTimestamp / 1000, 0)
            if (isKeyframe) {
                needsKeyframe = false
            }
        } catch (e: Exception) {
            needsKeyframe = true
            requestKeyframe("queue input failed")
            Log.e(TAG, "decode direct feed error", e)
        } finally {
            onFrameDecoded?.invoke(frameData)
        }
    }

    private fun dropFrame(
        frameData: ByteArray,
        isKeyframe: Boolean,
        reason: String,
        waitForKeyframe: Boolean,
        requestRefresh: Boolean = waitForKeyframe,
    ) {
        droppedFrames++
        if (droppedFrames <= 3L || droppedFrames % 60L == 0L) {
            diagLog("Dropping frame ($reason, keyframe=$isKeyframe, dropped=$droppedFrames)")
        }
        if (waitForKeyframe) {
            needsKeyframe = true
        }
        if (requestRefresh) {
            requestKeyframe(reason)
        }
        onFrameDecoded?.invoke(frameData)
    }

    private fun requestKeyframe(
        reason: String,
        force: Boolean = false,
    ) {
        val now = System.nanoTime()
        val interval =
            if (force) FORCE_KEYFRAME_REQUEST_INTERVAL_NS else KEYFRAME_REQUEST_INTERVAL_NS
        if (now - lastKeyframeRequestNs < interval) {
            return
        }
        lastKeyframeRequestNs = now
        diagLog("Requesting keyframe: reason=$reason, force=$force")
        onKeyframeRequired?.invoke(force, reason)
    }

    private fun handleOutputBuffer(
        codec: MediaCodec,
        index: Int,
        info: MediaCodec.BufferInfo,
    ) {
        try {
            outputFrameCount++
            if (outputFrameCount == 1L) {
                diagLog("First output frame! size=${info.size}, flags=${info.flags}")
            }

            // Decoder latency: time from queueInputBuffer (where we encoded
            // System.nanoTime()/1000 as PTS) to now. Captures how long the
            // frame spent inside the codec's input/reorder/output queues.
            val nowNs = System.nanoTime()
            val latencyNs = nowNs - info.presentationTimeUs * 1000L
            val hasValidLatency = latencyNs in 0..MAX_REASONABLE_LATENCY_NS
            if (hasValidLatency) {
                latencySumNs += latencyNs
                latencySamples++
                if (latencyNs > latencyMaxNs) latencyMaxNs = latencyNs
            }

            if (outputFrameCount % 60L == 0L) {
                val avgMs = if (latencySamples > 0) latencySumNs / latencySamples / 1_000_000.0 else 0.0
                val maxMs = latencyMaxNs / 1_000_000.0
                val inBufs = availableInputBuffers.size
                diagLog(
                    "Output #$outputFrameCount: decoder latency avg=${"%.1f".format(avgMs)}ms " +
                        "max=${"%.1f".format(maxMs)}ms over $latencySamples samples, " +
                        "input bufs avail=$inBufs, dropped=$droppedFrames",
                )
                latencySumNs = 0
                latencySamples = 0
                latencyMaxNs = 0
            }

            val shouldRender =
                outputFrameCount == 1L ||
                    !hasValidLatency ||
                    latencyNs <= MAX_RENDER_LATENCY_NS

            if (!shouldRender) {
                droppedFrames++
                staleOutputDrops++
                if (staleOutputDrops <= 3L || staleOutputDrops % 60L == 0L) {
                    diagLog(
                        "Dropping stale output frame: latency=${"%.1f".format(latencyNs / 1_000_000.0)}ms, " +
                            "staleDrops=$staleOutputDrops",
                    )
                }
                codec.releaseOutputBuffer(index, false)
                updateStats()
                return
            }

            codec.releaseOutputBuffer(index, true)
            trackFrameTiming(System.nanoTime())
            updateStats()
        } catch (e: Exception) {
            Log.e(TAG, "releaseOutputBuffer failed", e)
            try {
                codec.releaseOutputBuffer(index, false)
            } catch (_: Exception) {
            }
        }
    }

    private fun trackFrameTiming(timestamp: Long) {
        frameTimes.addLast(timestamp)
        if (frameTimes.size > 120) frameTimes.removeFirst()

        if (frameTimes.size >= 60 && frameCount % 60L == 0L) {
            val deltas = frameTimes.zipWithNext { a, b -> (b - a) / 1_000_000.0 }
            if (deltas.isNotEmpty()) {
                val avgDelta = deltas.average()
                val variance = deltas.map { (it - avgDelta) * (it - avgDelta) }.average()
                val stdDev = kotlin.math.sqrt(variance)
                onFrameStats?.invoke(1000.0 / avgDelta, stdDev)
            }
        }
        onFrameRendered?.invoke(timestamp)
    }

    private fun updateStats() {
        frameCount++
        val now = System.currentTimeMillis()
        val elapsed = now - lastStatsTime
        if (elapsed >= 1000) {
            frameCount = 0
            droppedFrames = 0
            staleOutputDrops = 0
            lastStatsTime = now
        }
    }

    fun release() {
        isRunning = false
        try {
            availableInputBuffers.clear()
            decoder?.stop()
            decoder?.release()
            decoder = null
            decoderThread?.quitSafely()
            decoderThread = null
            decoderHandler = null
        } catch (_: Exception) {
        }
    }

    companion object {
        private const val TAG = "VideoDecoder"
        private const val KEYFRAME_REQUEST_INTERVAL_NS = 1_000_000_000L
        private const val FORCE_KEYFRAME_REQUEST_INTERVAL_NS = 200_000_000L
        private const val MAX_RENDER_LATENCY_NS = 100_000_000L
        private const val MAX_REASONABLE_LATENCY_NS = 2_000_000_000L
    }
}
