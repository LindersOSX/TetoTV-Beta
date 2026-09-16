package dev.animetv.anime_tv.aniyomi

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class AniyomiImageSafetyTest {
    @Test fun `accepts bounded PNG header and rejects HTML or dimension bomb`() {
        AniyomiImageSafety.inspect(png(width = 1200, height = 1800))
        rejects { AniyomiImageSafety.inspect("<html>private error</html>".toByteArray()) }
        rejects { AniyomiImageSafety.inspect(png(width = 8193, height = 1)) }
        rejects { AniyomiImageSafety.inspect(png(width = 8192, height = 8192)) }
    }

    @Test fun `recognizes only bounded ISO BMFF image brands`() {
        val avif = ByteArray(24).apply {
            put32be(this, 0, size)
            "ftyp".toByteArray().copyInto(this, 4)
            "avif".toByteArray().copyInto(this, 8)
            "avif".toByteArray().copyInto(this, 16)
        }
        assertTrue(AniyomiImageSafety.isIsoBmffImage(avif))
        avif[8] = 'm'.code.toByte()
        avif[9] = 'p'.code.toByte()
        avif[10] = '4'.code.toByte()
        avif[11] = '2'.code.toByte()
        avif[16] = 'm'.code.toByte()
        avif[17] = 'p'.code.toByte()
        avif[18] = '4'.code.toByte()
        avif[19] = '2'.code.toByte()
        assertFalse(AniyomiImageSafety.isIsoBmffImage(avif))
    }

    private fun png(width: Int, height: Int): ByteArray = ByteArray(24).apply {
        byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a).copyInto(this)
        put32be(this, 8, 13)
        "IHDR".toByteArray().copyInto(this, 12)
        put32be(this, 16, width)
        put32be(this, 20, height)
    }

    private fun put32be(target: ByteArray, offset: Int, value: Int) {
        target[offset] = (value ushr 24).toByte()
        target[offset + 1] = (value ushr 16).toByte()
        target[offset + 2] = (value ushr 8).toByte()
        target[offset + 3] = value.toByte()
    }

    private fun rejects(block: () -> Unit) {
        try {
            block()
            fail("Expected rejection")
        } catch (_: IllegalArgumentException) {
            // Expected.
        }
    }
}
