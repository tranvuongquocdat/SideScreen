package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceIdentityWireTest {
    private val uuid = "0f8fad5b-d9cb-469f-a165-70867728950e"

    @Test
    fun roundTrips() {
        val bytes = DeviceIdentityWire.encode(uuid, "SM-X710")!!
        assertEquals(uuid to "SM-X710", DeviceIdentityWire.decode(bytes))
    }

    @Test
    fun everyPayloadByteHasTheHighBitSet() {
        val bytes = DeviceIdentityWire.encode(uuid, "Pixel Tablet")!!
        assertEquals(DeviceIdentityWire.ENCODED_UUID_LENGTH + 1 + 2 * "Pixel Tablet".length, bytes.size)
        assertTrue(bytes.all { it.toInt() and 0x80 != 0 })
    }

    @Test
    fun matchesTheMacEncodingByteForByte() {
        // First UUID byte 0x0f → 0x80, 0x8f; count byte for "x" → 0x81; 'x' = 0x78 → 0x87, 0x88.
        val bytes = DeviceIdentityWire.encode(uuid, "x")!!
        assertEquals(0x80.toByte(), bytes[0])
        assertEquals(0x8f.toByte(), bytes[1])
        assertEquals(0x81.toByte(), bytes[32])
        assertEquals(0x87.toByte(), bytes[33])
        assertEquals(0x88.toByte(), bytes[34])
    }

    @Test
    fun nonAsciiNameRoundTrips() {
        val name = "Máy tính bảng"
        assertEquals(uuid to name, DeviceIdentityWire.decode(DeviceIdentityWire.encode(uuid, name)!!))
    }

    @Test
    fun overlongNameIsTruncated() {
        val bytes = DeviceIdentityWire.encode(uuid, "a".repeat(300))!!
        assertEquals(DeviceIdentityWire.MAX_NAME_BYTES, DeviceIdentityWire.decode(bytes)!!.second.length)
    }

    @Test
    fun invalidUuidIsRejected() {
        assertNull(DeviceIdentityWire.encode("not-a-uuid", "x"))
    }

    @Test
    fun malformedPayloadIsRejected() {
        val bytes = DeviceIdentityWire.encode(uuid, "ab")!!
        assertNull(DeviceIdentityWire.decode(bytes.copyOf(bytes.size - 1)))
        assertNull(DeviceIdentityWire.decode(bytes + 0x81.toByte()))
        val clearedBit = bytes.copyOf().also { it[3] = (it[3].toInt() and 0x7F).toByte() }
        assertNull(DeviceIdentityWire.decode(clearedBit))
    }
}
