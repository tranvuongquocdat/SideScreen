package com.sidescreen.app

import android.content.Context

private fun demoDiag(msg: String) = DiagLog.log("DM", msg)

/**
 * Demo mode: loops a bundled H.264 clip (assets/demo.h264, rendered by
 * scripts/make_demo_clip.py) through the real VideoDecoder so the app can be
 * tried without a Mac — Play reviewers and testers mostly don't have one.
 *
 * The clip is Annex-B with an AUD before every access unit and SPS/PPS on
 * every IDR, so frames split on AUD NALs and each keyframe decodes on its own.
 */
class DemoPlayer(
    context: Context,
    /** Returns the current decoder each frame — it is recreated on rotation/surface changes. */
    private val decoderProvider: () -> VideoDecoder?,
) {
    var onStats: ((fps: Double, mbps: Double) -> Unit)? = null

    private val frames: List<ByteArray>
    private val keyframes: BooleanArray

    @Volatile private var running = false
    private var thread: Thread? = null

    init {
        val data = context.assets.open(ASSET).use { it.readBytes() }
        frames = splitAccessUnits(data)
        keyframes = BooleanArray(frames.size) { StreamClient.isSyncFrame(frames[it], frames[it].size, isHevc = false) }
        demoDiag("Loaded ${frames.size} frames, ${keyframes.count { it }} keyframes, ${data.size} bytes")
    }

    fun start() {
        if (running || frames.isEmpty()) return
        running = true
        thread =
            Thread({ playLoop() }, "DemoPlayer").also {
                it.priority = Thread.MAX_PRIORITY
                it.start()
            }
    }

    fun stop() {
        running = false
        thread?.interrupt()
        thread = null
    }

    private fun playLoop() {
        val frameIntervalNs = 1_000_000_000L / FPS
        var next = System.nanoTime()
        var index = 0
        var statsFrames = 0
        var statsBytes = 0L
        var statsStart = System.nanoTime()
        try {
            while (running) {
                val frame = frames[index]
                decoderProvider()?.decode(frame, frame.size, System.nanoTime(), keyframes[index])
                statsFrames++
                statsBytes += frame.size
                index = (index + 1) % frames.size

                val now = System.nanoTime()
                if (now - statsStart >= 1_000_000_000L) {
                    val secs = (now - statsStart) / 1e9
                    onStats?.invoke(statsFrames / secs, statsBytes * 8 / secs / 1e6)
                    statsFrames = 0
                    statsBytes = 0
                    statsStart = now
                }

                next += frameIntervalNs
                val sleepNs = next - System.nanoTime()
                if (sleepNs > 0) {
                    Thread.sleep(sleepNs / 1_000_000, (sleepNs % 1_000_000).toInt())
                } else {
                    next = System.nanoTime() // fell behind (e.g. app paused) — don't burst
                }
            }
        } catch (_: InterruptedException) {
        }
    }

    companion object {
        const val ASSET = "demo.h264"
        const val WIDTH = 1680
        const val HEIGHT = 1050
        private const val FPS = 30

        /** Split an Annex-B stream into access units, cutting before each AUD (NAL type 9). */
        internal fun splitAccessUnits(data: ByteArray): List<ByteArray> {
            val starts = mutableListOf<Int>()
            var i = 0
            while (i + 3 < data.size) {
                if (data[i] == 0.toByte() && data[i + 1] == 0.toByte()) {
                    val scLen =
                        when {
                            data[i + 2] == 1.toByte() -> 3
                            data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte() -> 4
                            else -> 0
                        }
                    if (scLen > 0 && i + scLen < data.size) {
                        if ((data[i + scLen].toInt() and 0x1F) == 9) starts.add(i)
                        i += scLen
                        continue
                    }
                }
                i++
            }
            if (starts.isEmpty()) return if (data.isEmpty()) emptyList() else listOf(data)
            return starts.mapIndexed { n, start ->
                val end = if (n + 1 < starts.size) starts[n + 1] else data.size
                data.copyOfRange(start, end)
            }
        }
    }
}
