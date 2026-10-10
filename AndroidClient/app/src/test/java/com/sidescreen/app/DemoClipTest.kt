package com.sidescreen.app

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class DemoClipTest {
    private val aud = byteArrayOf(0, 0, 0, 1, 0x09, 0xF0.toByte())
    private val idr = byteArrayOf(0, 0, 0, 1, 0x65, 0x11, 0x22)
    private val slice = byteArrayOf(0, 0, 1, 0x41, 0x33)

    @Test
    fun splitsOnAccessUnitDelimiters() {
        val units = DemoPlayer.splitAccessUnits(aud + idr + aud + slice)
        assertEquals(2, units.size)
        assertArrayEquals(aud + idr, units[0])
        assertArrayEquals(aud + slice, units[1])
    }

    @Test
    fun streamWithoutDelimitersIsOneUnit() {
        val units = DemoPlayer.splitAccessUnits(idr + slice)
        assertEquals(1, units.size)
    }

    /** The bundled clip must start on a keyframe and recover at least every second. */
    @Test
    fun bundledClipStartsOnKeyframe() {
        val file = File("src/main/assets/${DemoPlayer.ASSET}")
        val units = DemoPlayer.splitAccessUnits(file.readBytes())
        assertTrue(units.size >= 300)
        val keys = units.map { StreamClient.isSyncFrame(it, it.size, isHevc = false) }
        assertTrue(keys[0])
        assertTrue(keys.indices.filter { keys[it] }.zipWithNext().all { (a, b) -> b - a <= 30 })
    }
}
