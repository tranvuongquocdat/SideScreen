package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FitStreamSizeTest {
    /**
     * Stand-in for VideoCapabilities.areSizeAndRateSupported: sides must respect the decoder's
     * alignment, and the macroblock count (rounded up, as Android counts it) times the rate must
     * fit the blocks-per-second budget.
     */
    private fun decoder(
        blocksPerSecond: Long,
        fps: Int,
        widthAlignment: Int = 2,
        heightAlignment: Int = 2,
    ): (Int, Int) -> Boolean =
        { w, h ->
            val blocks = ((w + 15) / 16).toLong() * ((h + 15) / 16).toLong()
            w % widthAlignment == 0 && h % heightAlignment == 0 && blocks * fps <= blocksPerSecond
        }

    private fun fit(
        panelWidth: Int,
        panelHeight: Int,
        supports: (Int, Int) -> Boolean,
        maxWidth: Int = 8192,
        maxHeight: Int = 8192,
        widthAlignment: Int = 2,
        heightAlignment: Int = 2,
    ) = CodecCapabilities.fitStreamSize(
        panelWidth,
        panelHeight,
        maxWidth,
        maxHeight,
        widthAlignment,
        heightAlignment,
        supports,
    )

    @Test
    fun panelWhoseHeightIsNotAMultipleOf16IsReportedExactly() {
        // Xiaomi Pad 6: 2880x1800, Snapdragon 870 HEVC (7,776,000 blocks/s). Used to report 2880x1792.
        val supports = decoder(blocksPerSecond = 7_776_000, fps = 120)
        assertEquals(2880 to 1800, fit(2880, 1800, supports))
    }

    @Test
    fun tenEightyPhoneIsReportedExactly() {
        // LG V510N from #88: 2340x1080 used to report 2336x1072.
        val supports = decoder(blocksPerSecond = 7_776_000, fps = 120)
        assertEquals(2340 to 1080, fit(2340, 1080, supports))
    }

    @Test
    fun nativeSizeRespectsTheDecodersOwnAlignment() {
        val supports = decoder(blocksPerSecond = 7_776_000, fps = 60, widthAlignment = 4, heightAlignment = 4)
        assertEquals(2340 to 1080, fit(2342, 1082, supports, widthAlignment = 4, heightAlignment = 4))
    }

    @Test
    fun overBudgetPanelStillShrinksOnSixteenAlignedSizes() {
        // Roughly a Level 4 decoder (about 1080p30 of blocks): the native size cannot be sustained.
        val supports = decoder(blocksPerSecond = 245_760, fps = 60)
        val size = fit(2000, 1200, supports)!!
        assertEquals(0, size.first % 16)
        assertEquals(0, size.second % 16)
        assertTrue(size.first < 2000)
        assertTrue(supports(size.first, size.second))
    }

    @Test
    fun panelLargerThanTheDecoderSkipsTheNativeAttempt() {
        val seen = mutableListOf<Pair<Int, Int>>()
        val supports: (Int, Int) -> Boolean = { w, h ->
            seen += w to h
            w <= 1920 && h <= 1088
        }
        val size = fit(2880, 1800, supports, maxWidth = 1920, maxHeight = 1088)!!
        assertTrue(seen.none { it == 2880 to 1800 })
        assertTrue(size.first <= 1920 && size.second <= 1088)
    }

    @Test
    fun nothingSupportedGivesNull() {
        assertNull(fit(2880, 1800, { _, _ -> false }))
    }
}
