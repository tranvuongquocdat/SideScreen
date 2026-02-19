package com.sidescreen.app

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.view.Choreographer
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

    var onFrameRendered: ((Long) -> Unit)? = null
    var onFrameStats: ((fps: Double, variance: Double) -> Unit)? = null
    var onFrameDecoded: ((ByteArray) -> Unit)? = null

    private val pendingFrames = ArrayBlockingQueue<FrameData>(2)

    private data class FrameData(
        val data: ByteArray,
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
        try {
            decoderThread = HandlerThread("DecoderThread", Process.THREAD_PRIORITY_DISPLAY).also { it.start() }
            decoderHandler = Handler(decoderThread!!.looper)

            decoder = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_HEVC)

            val format =
                MediaFormat.createVideoFormat(
                    MediaFormat.MIMETYPE_VIDEO_HEVC,
                    currentWidth,
                    currentHeight,
                )
            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            format.setInteger(MediaFormat.KEY_PRIORITY, 0)
            format.setInteger(MediaFormat.KEY_OPERATING_RATE, displayRefreshRate.toInt())
            format.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)

            decoder?.setCallback(
                object : MediaCodec.Callback() {
                    override fun onInputBufferAvailable(
                        codec: MediaCodec,
                        index: Int,
                    ) {
                        handleInputBuffer(codec, index)
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
                        // Codec error
                    }

                    override fun onOutputFormatChanged(
                        codec: MediaCodec,
                        format: MediaFormat,
                    ) {
                        // Format changed
                    }
                },
                decoderHandler,
            )

            decoder?.configure(format, surface, null, 0)
            decoder?.setVideoScalingMode(MediaCodec.VIDEO_SCALING_MODE_SCALE_TO_FIT)
            decoder?.start()
        } catch (e: Exception) {
            throw e
        }
    }

    fun decode(
        frameData: ByteArray,
        frameTimestamp: Long = System.nanoTime(),
    ) {
        val now = System.nanoTime()
        val frameAge = now - frameTimestamp
        if (frameAge > maxFrameAgeNs) {
            droppedFrames++
            onFrameDecoded?.invoke(frameData)
            return
        }

        if (!pendingFrames.offer(FrameData(frameData, frameTimestamp))) {
            val dropped = pendingFrames.poll()
            if (dropped != null) {
                droppedFrames++
                onFrameDecoded?.invoke(dropped.data)
            }
            pendingFrames.offer(FrameData(frameData, frameTimestamp))
        }
    }

    private fun handleInputBuffer(
        codec: MediaCodec,
        index: Int,
    ) {
        val frame =
            try {
                pendingFrames.poll(5, TimeUnit.MILLISECONDS)
            } catch (_: InterruptedException) {
                null
            }

        if (frame == null) return

        try {
            val inputBuffer = codec.getInputBuffer(index)
            inputBuffer?.clear()
            inputBuffer?.put(frame.data, 0, frame.data.size)
            codec.queueInputBuffer(index, 0, frame.data.size, frame.timestamp / 1000, 0)
        } catch (_: Exception) {
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
            Choreographer.getInstance().postFrameCallback { vsyncNanos ->
                try {
                    codec.releaseOutputBuffer(index, vsyncNanos)
                } catch (_: Exception) {
                }
            }

            trackFrameTiming(System.nanoTime())
            updateStats()
        } catch (_: Exception) {
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
}
