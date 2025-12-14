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

    var onFrameReceived: ((ByteArray) -> Unit)? = null
    var onConnectionStatus: ((Boolean) -> Unit)? = null
    var onDisplaySize: ((Int, Int) -> Unit)? = null
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
                        val frameSize = input.readInt()

                        if (frameSize <= 0 || frameSize > MAX_FRAME_SIZE) {
                            Log.e(TAG, "❌ Invalid frame size: $frameSize")
                            break
                        }

                        val frameData = ByteArray(frameSize)
                        input.readFully(frameData)
                        onFrameReceived?.invoke(frameData)
                        updateStats(frameSize)
                    }
                    1 -> { // Display size
                        val width = input.readInt()
                        val height = input.readInt()
                        onDisplaySize?.invoke(width, height)
                        Log.d(TAG, "Display size: ${width}x${height}")
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

    fun sendTouch(x: Float, y: Float, action: Int) {
        if (!isConnected) return

        // Send touch on high-priority thread to minimize latency
        touchScope.launch {
            try {
                outputStream?.apply {
                    writeByte(2) // Touch event type
                    writeFloat(x)
                    writeFloat(y)
                    writeInt(action)
                    flush()
                }
            } catch (e: Exception) {
                Log.e(TAG, "❌ Failed to send touch", e)
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
