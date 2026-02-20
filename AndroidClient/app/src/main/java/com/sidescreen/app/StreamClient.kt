package com.sidescreen.app

import android.os.Process
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.DataInputStream
import java.io.IOException
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class StreamClient(
    private val host: String,
    private val port: Int,
) {
    private var socket: Socket? = null
    private var inputStream: DataInputStream? = null
    private var outputStream: java.io.DataOutputStream? = null
    private var isConnected = false

    // Callback includes actual frame size (may differ from buffer.size due to pooling) and timestamp
    var onFrameReceived: ((ByteArray, Int, Long) -> Unit)? = null
    var onConnectionStatus: ((Boolean) -> Unit)? = null
    var onDisplaySize: ((Int, Int, Int) -> Unit)? = null // width, height, rotation
    var onStats: ((Double, Double) -> Unit)? = null

    private var bytesReceived = 0L
    private var framesReceived = 0L
    private var lastStatsTime = System.currentTimeMillis()

    // Buffer pooling to reduce GC pressure from per-frame allocations
    // At 60fps with ~100KB frames, this prevents ~6MB/s of allocations
    private val bufferPool = ArrayDeque<ByteArray>(8)
    private val poolLock = Any()

    /**
     * Acquire a buffer from pool or allocate new one if needed
     * @param minSize Minimum size required for the buffer
     */
    private fun acquireBuffer(minSize: Int): ByteArray {
        synchronized(poolLock) {
            val iterator = bufferPool.iterator()
            while (iterator.hasNext()) {
                val buffer = iterator.next()
                if (buffer.size >= minSize) {
                    iterator.remove()
                    return buffer
                }
            }
        }
        // No suitable buffer found, allocate new one
        return ByteArray(minSize)
    }

    /**
     * Release a buffer back to the pool for reuse
     * Called after decode completes via onFrameDecoded callback
     */
    fun releaseBuffer(buffer: ByteArray) {
        synchronized(poolLock) {
            // Keep pool size limited to prevent memory bloat
            if (bufferPool.size < 8) {
                bufferPool.addLast(buffer)
            }
            // If pool is full, let buffer be GC'd
        }
    }

    // High-priority thread for touch events to minimize latency
    // Use THREAD_PRIORITY_DISPLAY instead of URGENT_DISPLAY to avoid starving system processes
    private val touchExecutor =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable).apply {
                name = "TouchThread"
                priority = Thread.MAX_PRIORITY
                // Use DISPLAY priority (less aggressive than URGENT_DISPLAY)
                // URGENT_DISPLAY can starve system launcher and cause lag
                Process.setThreadPriority(Process.THREAD_PRIORITY_DISPLAY)
            }
        }
    private val touchDispatcher = touchExecutor.asCoroutineDispatcher()
    private val touchScope = CoroutineScope(touchDispatcher)

    suspend fun connect() =
        withContext(Dispatchers.IO) {
            try {
                socket =
                    Socket(host, port).apply {
                        tcpNoDelay = true
                    }
                inputStream = DataInputStream(java.io.BufferedInputStream(socket?.getInputStream(), 65536))
                outputStream = java.io.DataOutputStream(socket?.getOutputStream())
                isConnected = true

                Log.d(TAG, "✅ Connected to $host:$port")
                onConnectionStatus?.invoke(true)

                receiveData()
            } catch (e: Exception) {
                Log.e(TAG, "❌ Connection error", e)
                onConnectionStatus?.invoke(false)
                cleanup()
            }
        }

    private suspend fun receiveData() =
        withContext(Dispatchers.IO) {
            val input = inputStream ?: return@withContext

            try {
                while (isConnected) {
                    val type = input.readByte()

                    when (type.toInt()) {
                        0 -> { // Video frame
                            val frameSize = input.readInt()

                            if (frameSize <= 0 || frameSize > MAX_FRAME_SIZE) {
                                Log.e(TAG, "❌ Invalid frame size: $frameSize")
                                break
                            }

                            val frameData = acquireBuffer(frameSize)
                            input.readFully(frameData, 0, frameSize)

                            // Capture timestamp after full frame received for accurate age tracking
                            val receiveTimestamp = System.nanoTime()
                            onFrameReceived?.invoke(frameData, frameSize, receiveTimestamp)
                            updateStats(frameSize)
                        }

                        1 -> { // Display size + rotation
                            val width = input.readInt()
                            val height = input.readInt()
                            val rotation = input.readInt()
                            onDisplaySize?.invoke(width, height, rotation)
                            Log.d(TAG, "Display config: ${width}x$height @ $rotation°")
                        }
                    }
                }
            } catch (e: IOException) {
                if (isConnected) {
                    Log.e(TAG, "❌ Read error", e)
                }
            } finally {
                disconnect()
            }
        }

    fun sendTouch(
        x: Float,
        y: Float,
        action: Int,
        pointerCount: Int = 1,
        x2: Float = 0f,
        y2: Float = 0f,
    ) {
        if (!isConnected) return

        touchScope.launch {
            try {
                socket?.getOutputStream()?.let { out ->
                    val count = pointerCount.coerceIn(1, 2)
                    val size = 6 + count * 8 // 1 type + 1 count + N*(4x+4y) + 4 action
                    val buffer = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN)
                    buffer.put(2.toByte())
                    buffer.put(count.toByte())
                    buffer.putFloat(x)
                    buffer.putFloat(y)
                    if (count == 2) {
                        buffer.putFloat(x2)
                        buffer.putFloat(y2)
                    }
                    buffer.putInt(action)
                    out.write(buffer.array())
                    out.flush()
                }
            } catch (_: Exception) {
            }
        }
    }

    private fun updateStats(bytes: Int) {
        bytesReceived += bytes
        framesReceived++

        val now = System.currentTimeMillis()
        val elapsed = now - lastStatsTime

        if (elapsed >= 1000) {
            val mbps = (bytesReceived * 8.0) / (elapsed / 1000.0) / 1_000_000
            val fps = (framesReceived * 1000.0) / elapsed
            onStats?.invoke(fps, mbps)

            bytesReceived = 0
            framesReceived = 0
            lastStatsTime = now
        }
    }

    fun disconnect() {
        isConnected = false
        cleanup()
        onConnectionStatus?.invoke(false)
        Log.d(TAG, "Disconnected")
    }

    private fun cleanup() {
        try {
            outputStream?.close()
            inputStream?.close()
            socket?.close()

            // Properly shutdown executor with timeout to prevent orphaned threads
            touchExecutor.shutdown()
            try {
                if (!touchExecutor.awaitTermination(500, TimeUnit.MILLISECONDS)) {
                    touchExecutor.shutdownNow()
                    // Wait a bit more for forced shutdown
                    touchExecutor.awaitTermination(200, TimeUnit.MILLISECONDS)
                }
            } catch (e: InterruptedException) {
                touchExecutor.shutdownNow()
                Thread.currentThread().interrupt()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error during cleanup", e)
        }
        outputStream = null
        inputStream = null
        socket = null
    }

    companion object {
        private const val TAG = "StreamClient"
        private const val MAX_FRAME_SIZE = 5 * 1024 * 1024 // 5MB
    }
}
