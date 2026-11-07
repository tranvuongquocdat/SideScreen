package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Test

class OverlayBoundsTest {
    @Test
    fun keepsPositionInsideParent() {
        assertEquals(0f, OverlayBounds.clamp(-20f, parentSize = 1000, viewSize = 300), 0f)
        assertEquals(150f, OverlayBounds.clamp(150f, parentSize = 1000, viewSize = 300), 0f)
        assertEquals(700f, OverlayBounds.clamp(900f, parentSize = 1000, viewSize = 300), 0f)
    }

    @Test
    fun overlayWiderThanParentPinsToEdgeInsteadOfThrowing() {
        // Galaxy S22 Ultra portrait: status bar wider than its parent → maxX < 0.
        // 1.0.2 called coerceIn(0, maxX) here and crashed with IllegalArgumentException.
        assertEquals(0f, OverlayBounds.clamp(40f, parentSize = 400, viewSize = 600), 0f)
        assertEquals(0f, OverlayBounds.clamp(-40f, parentSize = 400, viewSize = 600), 0f)
    }

    @Test
    fun parentNotLaidOutYetPinsToOrigin() {
        assertEquals(0f, OverlayBounds.clamp(10f, parentSize = 0, viewSize = 300), 0f)
    }
}
