package com.sidescreen.app

/** Keeps the draggable status overlay inside its parent. */
object OverlayBounds {
    /**
     * Clamp [position] so a view of [viewSize] stays within a parent of [parentSize].
     *
     * When the view is wider/taller than its parent (phones in portrait), or the parent
     * is not laid out yet, the upper bound would be negative. `coerceIn(0f, negative)`
     * throws IllegalArgumentException — that was a 1.0.2 crash on a Galaxy S22 Ultra —
     * so the bound is floored at 0 and the view pins to the leading edge instead.
     */
    fun clamp(
        position: Float,
        parentSize: Int,
        viewSize: Int,
    ): Float {
        val max = (parentSize - viewSize).toFloat().coerceAtLeast(0f)
        return position.coerceIn(0f, max)
    }
}
