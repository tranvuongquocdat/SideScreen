package com.virtualdisplay.client

import android.os.SystemClock

/**
 * Predicts touch input position based on velocity to reduce perceived latency
 * Critical for FPS gaming where every millisecond counts
 */
class InputPredictor {
    private data class TouchSample(
        val x: Float,
        val y: Float,
        val timestamp: Long  // nanoseconds
    )

    private val history = ArrayDeque<TouchSample>(5)
    private val MIN_SAMPLES_FOR_PREDICTION = 2

    /**
     * Add a new touch sample to the history
     */
    fun addSample(x: Float, y: Float) {
        val timestamp = SystemClock.elapsedRealtimeNanos()
        history.addLast(TouchSample(x, y, timestamp))

        // Keep only last 5 samples for velocity calculation
        if (history.size > 5) {
            history.removeFirst()
        }
    }

    /**
     * Predict position after given latency in milliseconds
     * Uses linear extrapolation based on recent velocity
     *
     * @param latencyMs Expected latency in milliseconds (typically 10-20ms)
     * @return Pair of predicted (x, y) coordinates
     */
    fun predictPosition(latencyMs: Float): Pair<Float, Float> {
        if (history.size < MIN_SAMPLES_FOR_PREDICTION) {
            // Not enough data, return last known position
            return if (history.isEmpty()) {
                Pair(0f, 0f)
            } else {
                Pair(history.last().x, history.last().y)
            }
        }

        // Calculate velocity from last 2 samples (most recent)
        val prev = history[history.size - 2]
        val curr = history.last()

        // Time delta in milliseconds
        val dt = (curr.timestamp - prev.timestamp) / 1_000_000f

        if (dt < 0.1f) {
            // Samples too close together, might be noise
            return Pair(curr.x, curr.y)
        }

        // Velocity in units per millisecond
        val vx = (curr.x - prev.x) / dt
        val vy = (curr.y - prev.y) / dt

        // Extrapolate forward by latency amount
        val predictedX = curr.x + (vx * latencyMs)
        val predictedY = curr.y + (vy * latencyMs)

        return Pair(predictedX, predictedY)
    }

    /**
     * Get current velocity in units per second
     * Useful for debugging and adaptive latency compensation
     */
    fun getCurrentVelocity(): Pair<Float, Float> {
        if (history.size < 2) return Pair(0f, 0f)

        val prev = history[history.size - 2]
        val curr = history.last()
        val dt = (curr.timestamp - prev.timestamp) / 1_000_000_000f // nanoseconds to seconds

        return if (dt > 0) {
            Pair(
                (curr.x - prev.x) / dt,
                (curr.y - prev.y) / dt
            )
        } else {
            Pair(0f, 0f)
        }
    }

    /**
     * Reset predictor state (call when touch sequence ends)
     */
    fun reset() {
        history.clear()
    }
}
