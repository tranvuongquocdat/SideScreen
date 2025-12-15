package com.virtualdisplay.client

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.Process
import android.util.Log
import android.view.Choreographer
import android.view.Display
import android.view.Surface
import java.nio.ByteBuffer

class VideoDecoder(private val surface: Surface, private val display: Display? = null) {
    private var decoder: MediaCodec? = null
    private var frameCount = 0L
    private var droppedFrames = 0L
    private var lastStatsTime = System.currentTimeMillis()

    // Frame timing for consistency tracking
    private val frameTimes = ArrayDeque<Long>(120)
    private var lastFrameTime = 0L

    // Display refresh rate for vsync alignment
    private val displayRefreshRate = display?.refreshRate ?: 60f
    private val frameIntervalNs = (1_000_000_000.0 / displayRefreshRate).toLong()

    // Dynamic resolution support
    private var currentWidth = 1920
    private var currentHeight = 1200

    // Frame age limit for dropping old frames (50ms in nanoseconds)
    private val maxFrameAgeNs = 50_000_000L

    var onFrameRendered: ((Long) -> Unit)? = null
    var onFrameStats: ((fps: Double, variance: Double) -> Unit)? = null

    init {
        setupDecoder()
        pinThreadToPerformanceCores()
    }

    /**
     * Update resolution when server sends new display config
     * Will recreate decoder if resolution changed
     */
    fun updateResolution(width: Int, height: Int) {
        if (width != currentWidth || height != currentHeight) {
            Log.d(TAG, "📐 Resolution changed: ${currentWidth}x${currentHeight} -> ${width}x${height}")
            currentWidth = width
            currentHeight = height
            // Recreate decoder with new resolution
            release()
            setupDecoder()
            pinThreadToPerformanceCores()
        }
    }

    /**
     * Pin decoder thread to performance cores (Cortex-A715 on Dimensity 8300)
     * Cores 4-7 are typically the big cores on MediaTek chips
     */
    private fun pinThreadToPerformanceCores() {
        try {
            val tid = Process.myTid()
            // Set thread priority to urgent display for minimal latency
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_DISPLAY)

            // Try to set CPU affinity to performance cores (4-7 on Dimensity 8300)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                try {
                    // This requires root or specific permissions, so we wrap in try-catch
                    val osClass = Class.forName("android.system.Os")
                    val cpuSet = Class.forName("android.system.StructCpuSet")
                    Log.d(TAG, "🎯 Attempting to pin thread $tid to performance cores")
                } catch (e: Exception) {
                    Log.d(TAG, "⚠️ Could not set CPU affinity (expected on non-rooted devices)")
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to optimize thread priority: ${e.message}")
        }
    }

    private fun setupDecoder() {
        try {
            decoder = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_HEVC)

            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, currentWidth, currentHeight)

            // Critical low-latency settings
            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            format.setInteger(MediaFormat.KEY_PRIORITY, 0) // Highest priority

            // Operating rate - match display refresh rate
            format.setInteger(MediaFormat.KEY_OPERATING_RATE, displayRefreshRate.toInt())

            // Disable B-frames for lower latency
            format.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)

            decoder?.configure(format, surface, null, 0)

            // Set operating mode for low latency (Android 11+)
            decoder?.setVideoScalingMode(MediaCodec.VIDEO_SCALING_MODE_SCALE_TO_FIT)

            decoder?.start()

            Log.d(TAG, "✅ MediaCodec decoder started (H.265, ${currentWidth}x${currentHeight}, ${displayRefreshRate}fps)")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to setup decoder", e)
            throw e
        }
    }

    fun decode(frameData: ByteArray, frameTimestamp: Long = System.nanoTime()) {
        val decoder = this.decoder ?: return

        try {
            // Check frame age - drop old frames to prevent latency buildup
            val now = System.nanoTime()
            val frameAge = now - frameTimestamp
            if (frameAge > maxFrameAgeNs) {
                droppedFrames++
                return  // Skip this old frame
            }

            // Increased timeout to 5ms for reliability (was 1ms - too aggressive)
            val inputBufferIndex = decoder.dequeueInputBuffer(5000)
            if (inputBufferIndex < 0) {
                droppedFrames++
                return  // No input buffer available
            }

            val inputBuffer = decoder.getInputBuffer(inputBufferIndex)
            inputBuffer?.clear()
            inputBuffer?.put(frameData)

            decoder.queueInputBuffer(
                inputBufferIndex,
                0,
                frameData.size,
                frameTimestamp / 1000,  // Use actual frame timestamp
                0
            )

            // Process output - handle format change BEFORE the main loop
            val bufferInfo = MediaCodec.BufferInfo()
            var outputBufferIndex = decoder.dequeueOutputBuffer(bufferInfo, 0)

            // Handle format change first
            if (outputBufferIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                val newFormat = decoder.outputFormat
                Log.d(TAG, "Format changed: $newFormat")
                outputBufferIndex = decoder.dequeueOutputBuffer(bufferInfo, 0)
            }

            // Process all available output frames
            while (outputBufferIndex >= 0) {
                val outputTime = System.nanoTime()

                // Align to next vsync interval for smooth presentation
                val vsyncsElapsed = (outputTime / frameIntervalNs)
                val nextVsync = (vsyncsElapsed + 1) * frameIntervalNs

                decoder.releaseOutputBuffer(outputBufferIndex, nextVsync)

                trackFrameTiming(outputTime)
                lastFrameTime = outputTime
                updateStats()

                outputBufferIndex = decoder.dequeueOutputBuffer(bufferInfo, 0)
            }

        } catch (e: Exception) {
            Log.e(TAG, "❌ Decode error", e)
        }
    }

    /**
     * Track frame timing to calculate consistency (variance)
     * Lower variance = smoother gameplay
     */
    private fun trackFrameTiming(timestamp: Long) {
        frameTimes.addLast(timestamp)
        if (frameTimes.size > 120) {
            frameTimes.removeFirst()
        }

        // Calculate frame time variance every 60 frames
        if (frameTimes.size >= 60 && frameCount % 60L == 0L) {
            val deltas = frameTimes.zipWithNext { a, b -> (b - a) / 1_000_000.0 } // Convert to ms
            if (deltas.isNotEmpty()) {
                val avgDelta = deltas.average()
                val variance = deltas.map { (it - avgDelta) * (it - avgDelta) }.average()
                val stdDev = kotlin.math.sqrt(variance)

                onFrameStats?.invoke(1000.0 / avgDelta, stdDev)

                Log.d(TAG, "📊 Frame consistency: avg=${String.format("%.1f", avgDelta)}ms, σ=${String.format("%.2f", stdDev)}ms")
            }
        }

        onFrameRendered?.invoke(timestamp)
    }

    private fun updateStats() {
        frameCount++
        val now = System.currentTimeMillis()
        val elapsed = now - lastStatsTime

        if (elapsed >= 1000) {  // Log every 1 second for more responsive stats
            val fps = (frameCount * 1000.0) / elapsed
            if (droppedFrames > 0) {
                Log.d(TAG, "📊 Decoder: ${String.format("%.1f", fps)} fps, dropped: $droppedFrames")
            } else {
                Log.d(TAG, "📊 Decoder: ${String.format("%.1f", fps)} fps")
            }

            frameCount = 0
            droppedFrames = 0
            lastStatsTime = now
        }
    }

    fun release() {
        try {
            decoder?.stop()
            decoder?.release()
            decoder = null
            Log.d(TAG, "Decoder released")
        } catch (e: Exception) {
            Log.e(TAG, "Error releasing decoder", e)
        }
    }

    companion object {
        private const val TAG = "VideoDecoder"
        private const val TIMEOUT_US = 10000L // 10ms
    }
}
