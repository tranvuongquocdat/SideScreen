package com.virtualdisplay.client

import android.media.MediaCodec
import android.media.MediaFormat
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer

class VideoDecoder(private val surface: Surface) {
    private var decoder: MediaCodec? = null
    private var frameCount = 0L
    private var lastStatsTime = System.currentTimeMillis()

    init {
        setupDecoder()
    }

    private fun setupDecoder() {
        try {
            decoder = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_HEVC)

            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, 1920, 1200)

            // Critical low-latency settings
            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            format.setInteger(MediaFormat.KEY_PRIORITY, 0) // Highest priority

            // Operating rate for 60fps
            format.setInteger(MediaFormat.KEY_OPERATING_RATE, 60)

            // Disable B-frames for lower latency
            format.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)

            decoder?.configure(format, surface, null, 0)

            // Set operating mode for low latency (Android 11+)
            decoder?.setVideoScalingMode(MediaCodec.VIDEO_SCALING_MODE_SCALE_TO_FIT)

            decoder?.start()

            Log.d(TAG, "✅ MediaCodec decoder started (H.265, 60fps, ultra-low latency)")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to setup decoder", e)
            throw e
        }
    }

    fun decode(frameData: ByteArray) {
        val decoder = this.decoder ?: return

        try {
            // Reduced timeout for lower latency (1ms instead of 5000ms)
            val inputBufferIndex = decoder.dequeueInputBuffer(1000)
            if (inputBufferIndex >= 0) {
                val inputBuffer = decoder.getInputBuffer(inputBufferIndex)
                inputBuffer?.clear()
                inputBuffer?.put(frameData)

                decoder.queueInputBuffer(
                    inputBufferIndex,
                    0,
                    frameData.size,
                    System.nanoTime() / 1000,
                    0
                )
            }

            // Process all available output frames immediately
            val bufferInfo = MediaCodec.BufferInfo()
            var outputBufferIndex = decoder.dequeueOutputBuffer(bufferInfo, 0)

            while (outputBufferIndex >= 0) {
                // Render immediately with timestamp for better frame pacing
                decoder.releaseOutputBuffer(outputBufferIndex, bufferInfo.presentationTimeUs * 1000)
                updateStats()
                outputBufferIndex = decoder.dequeueOutputBuffer(bufferInfo, 0)
            }

            when (outputBufferIndex) {
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val newFormat = decoder.outputFormat
                    Log.d(TAG, "Format changed: $newFormat")
                }
                MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    // No output available yet
                }
            }

        } catch (e: Exception) {
            Log.e(TAG, "❌ Decode error", e)
        }
    }

    private fun updateStats() {
        frameCount++
        val now = System.currentTimeMillis()
        val elapsed = now - lastStatsTime

        if (elapsed >= 2000) { // Log every 2 seconds
            val fps = (frameCount * 1000.0) / elapsed
            Log.d(TAG, "📊 Decoder stats: ${String.format("%.1f", fps)} fps")

            frameCount = 0
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
