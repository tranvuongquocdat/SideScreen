package com.sidescreen.app

import java.util.UUID

/**
 * Wire type 18 payload: this tablet's stable UUID and model name, so the Mac can bring back this
 * tablet's own settings every time. Every byte has the high bit set, like types 11 and 14, so a
 * Mac that predates the type and skips unknown input one byte at a time is never misaligned.
 *
 *     [16 UUID bytes, each as 0x80|hi-nibble 0x80|lo-nibble]   32 bytes
 *     [0x80 | name byte count]                                  1 byte
 *     [name UTF-8 bytes, nibble-encoded the same way]           2×count
 */
object DeviceIdentityWire {
    const val UUID_BYTES = 16
    const val ENCODED_UUID_LENGTH = 2 * UUID_BYTES

    /** Longest name the single count byte can carry. */
    const val MAX_NAME_BYTES = 0x7F

    /** Null when [uuid] is not a UUID string. */
    fun encode(
        uuid: String,
        name: String,
    ): ByteArray? {
        val parsed =
            try {
                UUID.fromString(uuid)
            } catch (_: IllegalArgumentException) {
                return null
            }
        var nameBytes = name.toByteArray(Charsets.UTF_8)
        if (nameBytes.size > MAX_NAME_BYTES) nameBytes = nameBytes.copyOf(MAX_NAME_BYTES)

        val out = ByteArray(ENCODED_UUID_LENGTH + 1 + 2 * nameBytes.size)
        var at = 0
        for (word in longArrayOf(parsed.mostSignificantBits, parsed.leastSignificantBits)) {
            for (shift in 56 downTo 0 step 8) {
                val byte = ((word ushr shift) and 0xFF).toInt()
                out[at++] = (0x80 or (byte ushr 4)).toByte()
                out[at++] = (0x80 or (byte and 0x0F)).toByte()
            }
        }
        out[at++] = (0x80 or nameBytes.size).toByte()
        for (b in nameBytes) {
            val byte = b.toInt() and 0xFF
            out[at++] = (0x80 or (byte ushr 4)).toByte()
            out[at++] = (0x80 or (byte and 0x0F)).toByte()
        }
        return out
    }

    /** Inverse of [encode], for tests. Null unless the payload is exactly one well-formed identity. */
    fun decode(bytes: ByteArray): Pair<String, String>? {
        if (bytes.size < ENCODED_UUID_LENGTH + 1) return null
        if (bytes.any { it.toInt() and 0x80 == 0 }) return null
        val count = bytes[ENCODED_UUID_LENGTH].toInt() and 0x7F
        if (bytes.size != ENCODED_UUID_LENGTH + 1 + 2 * count) return null

        fun byteAt(pair: Int): Int = ((bytes[pair].toInt() and 0x0F) shl 4) or (bytes[pair + 1].toInt() and 0x0F)

        var msb = 0L
        var lsb = 0L
        for (i in 0 until 8) msb = (msb shl 8) or byteAt(2 * i).toLong()
        for (i in 8 until 16) lsb = (lsb shl 8) or byteAt(2 * i).toLong()
        val name = ByteArray(count) { byteAt(ENCODED_UUID_LENGTH + 1 + 2 * it).toByte() }
        return UUID(msb, lsb).toString() to String(name, Charsets.UTF_8)
    }
}
