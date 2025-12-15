package com.virtualdisplay.client

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

class StreamClient(
    private val host: String,
    private val port: Int
) {
    private var socket: Socket? = null
    private var inputStream: DataInputStream? = null
    private var outputStream: java.io.DataOutputStream? = null
    private var isConnected = false

    // Callback now includes timestamp for frame age tracking
    var onFrameReceived: ((ByteArray, Long) -> Unit)? = null
    var onConnectionStatus: ((Boolean) -> Unit)? = null
    var onDisplaySize: ((Int, Int, Int) -> Unit)? = null  // width, height, rotation
    var onStats: ((Double, Double) -> Unit)? = null

    private var bytesReceived = 0L
    private var framesReceived = 0L
    private var lastStatsTime = System.currentTimeMillis()

    // High-priority thread for touch events to minimize latency
    private val touchExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable).apply {
            name = "TouchThread"
            priority = Thread.MAX_PRIORITY
            // Set to urgent display priority
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_DISPLAY)
        }
    }
    private val touchDispatcher = touchExecutor.asCoroutineDispatcher()
    private val touchScope = CoroutineScope(touchDispatcher)

    suspend fun connect() = withContext(Dispatchers.IO) {
        try {
            socket = Socket(host, port)
            inputStream = DataInputStream(socket?.getInputStream())
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

    private suspend fun receiveData() = withContext(Dispatchers.IO) {
        val input = inputStream ?: return@withContext

        try {
            while (isConnected) {
                val type = input.readByte()

                when (type.toInt()) {
                    0 -> { // Video frame
                        // Capture timestamp as early as possible
                        val receiveTimestamp = System.nanoTime()

                        val frameSize = input.readInt()

                        if (frameSize <= 0 || frameSize > MAX_FRAME_SIZE) {
                            Log.e(TAG, "❌ Invalid frame size: $frameSize")
                            break
                        }

                        val frameData = ByteArray(frameSize)
                        input.readFully(frameData)

                        // Pass timestamp to decoder for frame age tracking
                        onFrameReceived?.invoke(frameData, receiveTimestamp)
                        updateStats(frameSize)
                    }
                    1 -> { // Display size + rotation
                        val width = input.readInt()
                        val height = input.readInt()
                        val rotation = input.readInt()
                        onDisplaySize?.invoke(width, height, rotation)
                        Log.d(TAG, "Display config: ${width}x${height} @ ${rotation}°")
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

    private val touchBuffer = ByteBuffer.allocate(13).order(ByteOrder.LITTLE_ENDIAN)

    fun sendTouch(x: Float, y: Float, action: Int) {
        if (!isConnected) return

        touchScope.launch {
            try {
                socket?.getOutputStream()?.let { out ->
                    synchronized(touchBuffer) {
                        touchBuffer.clear()
                        touchBuffer.put(2.toByte())
                        touchBuffer.putFloat(x)
                        touchBuffer.putFloat(y)
                        touchBuffer.putInt(action)
                        out.write(touchBuffer.array())
                        out.flush()
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to send touch", e)
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

            Log.d(TAG, "📊 Network stats: ${String.format("%.1f", fps)} fps, ${String.format("%.2f", mbps)} Mbps")
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
            touchExecutor.shutdown()
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
