package dev.animetv.anime_tv.aniyomi

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AniyomiDexLocalProxyDetectorTest {
    @Test fun `minified local HLS server is detected from independent DEX signals`() {
        val signals = inspect(
            "Ljava/net/ServerSocket;",
            "Ljava/net/InetSocketAddress;",
            "http://localhost:",
            "NanoHttpd Main Listener",
        )

        assertTrue(signals.serverSocket)
        assertTrue(signals.inetSocketAddress)
        assertTrue(signals.loopbackMarker)
        assertTrue(signals.requiresLocalProxy)
    }

    @Test fun `NanoHTTPD marker can independently establish the proxy signal`() {
        val signals = inspect(
            "Ljava/net/ServerSocket;",
            "Ljava/net/InetSocketAddress;",
            "NanoHttpd Main Listener",
        )

        assertTrue(signals.nanoHttpdMarker)
        assertTrue(signals.requiresLocalProxy)
    }

    @Test fun `generic socket usage without a local proxy marker remains supported`() {
        val signals = inspect(
            "Ljava/net/ServerSocket;",
            "Ljava/net/InetSocketAddress;",
            "https://media.example/video.m3u8",
        )

        assertFalse(signals.requiresLocalProxy)
    }

    @Test fun `a loopback label alone cannot classify an extension`() {
        val signals = inspect("localhost", "Ljava/net/ServerSocket;")

        assertFalse(signals.requiresLocalProxy)
    }

    @Test fun `explicit loopback API is accepted as the third independent marker`() {
        val signals = inspect(
            "Ljava/net/ServerSocket;",
            "Ljava/net/InetSocketAddress;",
            "Ljava/net/InetAddress;",
            "getLoopbackAddress",
        )

        assertTrue(signals.requiresLocalProxy)
    }

    @Test fun `signals can be split across bounded multidex entries`() {
        val socketDex = inspect("Ljava/net/ServerSocket;", "Ljava/net/InetSocketAddress;")
        val markerDex = inspect("http://127.0.0.1:8192/proxy")

        assertTrue(socketDex.merge(markerDex).requiresLocalProxy)
    }

    @Test fun `malformed DEX offsets fail closed`() {
        val malformed = dexWithStrings("Ljava/net/ServerSocket;")
        putUInt(malformed, 0x3c, malformed.size + 1)

        assertNull(AniyomiDexLocalProxyDetector.inspect(malformed))
    }

    @Test fun `only video and page execution is gated with fixed diagnostics`() {
        assertEquals(
            "source_videos",
            AniyomiExtensionCapabilityPolicy.rejection("videos", true)?.stage,
        )
        assertEquals(
            "source_pages",
            AniyomiExtensionCapabilityPolicy.rejection("pages", true)?.stage,
        )
        for (operation in listOf("sources", "search", "details", "seasons", "episodes", "chapters")) {
            assertNull(operation, AniyomiExtensionCapabilityPolicy.rejection(operation, true))
        }
        assertNull(AniyomiExtensionCapabilityPolicy.rejection("videos", false))
        assertNull(AniyomiExtensionCapabilityPolicy.rejection("pages", false))
    }

    private fun inspect(vararg strings: String): AniyomiDexLocalProxyDetector.Signals {
        val result = AniyomiDexLocalProxyDetector.inspect(dexWithStrings(*strings))
        assertNotNull(result)
        return result!!
    }

    /** Minimal structural DEX fixture; production code reads only these bounded fields. */
    private fun dexWithStrings(vararg strings: String): ByteArray {
        val headerSize = 0x70
        val idsOffset = headerSize
        val dataOffset = idsOffset + strings.size * 4
        val encoded = strings.map { text ->
            require(text.length < 0x80 && text.all { it.code in 1..0x7f })
            byteArrayOf(text.length.toByte()) + text.toByteArray(Charsets.US_ASCII) + byteArrayOf(0)
        }
        val total = dataOffset + encoded.sumOf(ByteArray::size)
        val bytes = ByteArray(total)
        "dex\n035\u0000".toByteArray(Charsets.US_ASCII).copyInto(bytes)
        putUInt(bytes, 0x20, total)
        putUInt(bytes, 0x24, headerSize)
        putUInt(bytes, 0x28, 0x12345678)
        putUInt(bytes, 0x38, strings.size)
        putUInt(bytes, 0x3c, idsOffset)
        var cursor = dataOffset
        encoded.forEachIndexed { index, value ->
            putUInt(bytes, idsOffset + index * 4, cursor)
            value.copyInto(bytes, cursor)
            cursor += value.size
        }
        return bytes
    }

    private fun putUInt(bytes: ByteArray, offset: Int, value: Int) {
        bytes[offset] = value.toByte()
        bytes[offset + 1] = (value ushr 8).toByte()
        bytes[offset + 2] = (value ushr 16).toByte()
        bytes[offset + 3] = (value ushr 24).toByte()
    }
}
