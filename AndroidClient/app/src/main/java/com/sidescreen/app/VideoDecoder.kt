package com.sidescreen.app

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.util.Log
import android.view.Display
import android.view.Surface
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

class VideoDecoder(
    private val surface: Surface,
    private val display: Display? = null,
) {
    private var decoder: MediaCodec? = null
    private var decoderThread: HandlerThread? = null
    private var decoderHandler: Handler? = null

    private var frameCount = 0L
    private var droppedFrames = 0L
    private var lastStatsTime = System.currentTimeMillis()

    private val frameTimes = ArrayDeque<Long>(120)

    private val displayRefreshRate = display?.refreshRate ?: 60f

    private var currentWidth = 1920
    private var currentHeight = 1200

    private val maxFrameAgeNs = 60_000_000L
    @Volatile private var isRunning = false

    var onFrameRendered: ((Long) -> Unit)? = null
    var onFrameStats: ((fps: Double, variance: Double) -> Unit)? = null
    var onFrameDecoded: ((ByteArray) -> Unit)? = null

    private val pendingFrames = ArrayBlockingQueue<FrameData>(2)

    private data class FrameData(
        val data: ByteArray,
        val size: Int,
        val timestamp: Long,
    )

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
        }
    }

    private fun setupDecoder() {
        decoderThread = HandlerThread("DecoderThread", Process.THREAD_PRIORITY_DISPLAY).also { it.start() }
        decoderHandler = Handler(decoderThread!!.looper)

        val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_HEVC)

        val callback = object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                handleInputBuffer(codec, index)
            }
            override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                handleOutputBuffer(codec, index, info)
            }
            override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                Log.e(TAG, "Codec error: ${e.diagnosticInfo}", e)
            }
            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                Log.d(TAG, "Output format: $format")
            }
        }
        codec.setCallback(callback, decoderHandler)

        // Try configure with low-latency keys first, fallback without them
        // Some chipsets (e.g. MediaTek) throw IllegalArgumentException with certain keys
        val format = MediaFormat.createVideoFormat(
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
        } catch (e: Exception) {
            Log.w(TAG, "Full low-latency config failed, trying fallback: ${e.message}")
            codec.reset()
            codec.setCallback(callback, decoderHandler)
        }

        // Attempt 2: Without KEY_LOW_LATENCY
        if (!configured) {
            try {
                val basicFormat = MediaFormat.createVideoFormat(
                    MediaFormat.MIMETYPE_VIDEO_HEVC,
                    currentWidth,
                    currentHeight,
                )
                basicFormat.setInteger(MediaFormat.KEY_PRIORITY, 0)
                basicFormat.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
                codec.configure(basicFormat, surface, null, 0)
                configured = true
            } catch (e: Exception) {
                Log.w(TAG, "Basic config failed, trying minimal: ${e.message}")
                codec.reset()
                codec.setCallback(callback, decoderHandler)
            }
        }

        // Attempt 3: Minimal config (just resolution)
        if (!configured) {
            try {
                val minimalFormat = MediaFormat.createVideoFormat(
                    MediaFormat.MIMETYPE_VIDEO_HEVC,
                    currentWidth,
                    currentHeight,
                )
                codec.configure(minimalFormat, surface, null, 0)
                configured = true
            } catch (e: Exception) {
                Log.e(TAG, "All configure attempts failed", e)
                codec.release()
                decoderThread?.quitSafely()
                decoderThread = null
                decoderHandler = null
                throw e
            }
        }

        codec.setVideoScalingMode(MediaCodec.VIDEO_SCALING_MODE_SCALE_TO_FIT)
        isRunning = true
        codec.start()
        decoder = codec
        Log.d(TAG, "Decoder started: ${currentWidth}x${currentHeight} @ ${displayRefreshRate}Hz")
    }

    fun decode(
        frameData: ByteArray,
        frameSize: Int = frameData.size,
        frameTimestamp: Long = System.nanoTime(),
    ) {
        val now = System.nanoTime()
        val frameAge = now - frameTimestamp
        if (frameAge > maxFrameAgeNs) {
            droppedFrames++
            onFrameDecoded?.invoke(frameData)
            return
        }

        if (!pendingFrames.offer(FrameData(frameData, frameSize, frameTimestamp))) {
            val dropped = pendingFrames.poll()
            if (dropped != null) {
                droppedFrames++
                onFrameDecoded?.invoke(dropped.data)
            }
            pendingFrames.offer(FrameData(frameData, frameSize, frameTimestamp))
        }
    }

    private fun handleInputBuffer(
        codec: MediaCodec,
        index: Int,
    ) {
        // Block until a frame is available.
        // In async mode, onInputBufferAvailable fires ONCE per buffer.
        // If we return without queueing, that buffer is lost forever.
        var frame: FrameData? = null
        while (frame == null && isRunning) {
            try {
                frame = pendingFrames.poll(500, TimeUnit.MILLISECONDS)
            } catch (_: InterruptedException) {
                return
            }
        }

        if (frame == null) return

        try {
            val inputBuffer = codec.getInputBuffer(index)
            inputBuffer?.clear()
            inputBuffer?.put(frame.data, 0, frame.size)
            codec.queueInputBuffer(index, 0, frame.size, frame.timestamp / 1000, 0)
        } catch (e: Exception) {
            Log.e(TAG, "handleInputBuffer error", e)
        } finally {
            onFrameDecoded?.invoke(frame.data)
        }
    }

    private fun handleOutputBuffer(
        codec: MediaCodec,
        index: Int,
        info: MediaCodec.BufferInfo,
    ) {
        try {
            codec.releaseOutputBuffer(index, true)
            trackFrameTiming(System.nanoTime())
            updateStats()
        } catch (e: Exception) {
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
            lastStatsTime = now
        }
    }

    fun release() {
        isRunning = false
        try {
            pendingFrames.clear()
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
    }
}
