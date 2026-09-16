package dev.animetv.anime_tv.aniyomi

/**
 * Bounded, side-effect-free inspection of the DEX string table.
 *
 * An isolated Aniyomi worker is not allowed to listen on a local socket. Some
 * extensions bundle a minified NanoHTTPD-style HLS proxy and only start it
 * while resolving videos or manga pages. Letting that code run can terminate
 * the isolated worker before it can return a structured failure. We therefore
 * require three independent signals before classifying an APK: server-socket
 * support, socket-address construction, and an explicit loopback/NanoHTTPD
 * marker. Generic network clients that merely mention one of these APIs are
 * not classified.
 *
 * Only the DEX string-id table is inspected. Raw bytes outside that table,
 * resources, package names, hashes and marketplace metadata cannot influence
 * the decision.
 */
internal object AniyomiDexLocalProxyDetector {
    internal data class Signals(
        val serverSocket: Boolean = false,
        val inetSocketAddress: Boolean = false,
        val loopbackMarker: Boolean = false,
        val nanoHttpdMarker: Boolean = false,
        val inetAddress: Boolean = false,
        val getLoopbackAddress: Boolean = false,
    ) {
        val requiresLocalProxy: Boolean
            get() = serverSocket && inetSocketAddress &&
                (loopbackMarker || nanoHttpdMarker || inetAddress && getLoopbackAddress)

        fun merge(other: Signals): Signals = Signals(
            serverSocket = serverSocket || other.serverSocket,
            inetSocketAddress = inetSocketAddress || other.inetSocketAddress,
            loopbackMarker = loopbackMarker || other.loopbackMarker,
            nanoHttpdMarker = nanoHttpdMarker || other.nanoHttpdMarker,
            inetAddress = inetAddress || other.inetAddress,
            getLoopbackAddress = getLoopbackAddress || other.getLoopbackAddress,
        )
    }

    /** Returns null for a malformed or unsupported DEX layout. */
    fun inspect(dex: ByteArray): Signals? {
        if (dex.size < DEX_HEADER_BYTES ||
            dex[0] != 'd'.code.toByte() || dex[1] != 'e'.code.toByte() ||
            dex[2] != 'x'.code.toByte() || dex[3] != '\n'.code.toByte() ||
            dex[7] != 0.toByte() || readUInt(dex, ENDIAN_TAG_OFFSET) != STANDARD_ENDIAN_TAG
        ) return null

        val stringCount = readUInt(dex, STRING_IDS_SIZE_OFFSET) ?: return null
        val stringIdsOffset = readUInt(dex, STRING_IDS_OFFSET_OFFSET) ?: return null
        if (stringCount == 0L || stringCount > MAX_STRING_IDS ||
            stringIdsOffset < DEX_HEADER_BYTES ||
            stringIdsOffset + stringCount * UINT_BYTES > dex.size.toLong()
        ) return null

        var signals = Signals()
        var inspectedStringBytes = 0L
        for (index in 0 until stringCount.toInt()) {
            val idOffset = stringIdsOffset + index.toLong() * UINT_BYTES
            val stringOffset = readUInt(dex, idOffset.toInt()) ?: return null
            if (stringOffset < DEX_HEADER_BYTES || stringOffset >= dex.size) return null
            val payloadStart = skipUleb128(dex, stringOffset.toInt()) ?: return null
            val payloadEnd = findTerminator(dex, payloadStart) ?: return null
            inspectedStringBytes += payloadEnd.toLong() - payloadStart + 1L
            // Valid string-data items occupy the same bounded DEX. Reject
            // pathological overlapping/repeated offsets before they can turn
            // inspection into quadratic work.
            if (inspectedStringBytes > dex.size.toLong() * MAX_STRING_SCAN_FACTOR) return null
            signals = inspectString(dex, payloadStart, payloadEnd, signals)
            if (signals.requiresLocalProxy) return signals
        }
        return signals
    }

    private fun inspectString(bytes: ByteArray, start: Int, end: Int, current: Signals): Signals {
        var serverSocket = current.serverSocket
        var inetSocketAddress = current.inetSocketAddress
        var loopbackMarker = current.loopbackMarker
        var nanoHttpdMarker = current.nanoHttpdMarker
        var inetAddress = current.inetAddress
        var getLoopbackAddress = current.getLoopbackAddress

        if (!serverSocket && (
                equalsAscii(bytes, start, end, "Ljava/net/ServerSocket;") ||
                    equalsAscii(bytes, start, end, "java.net.ServerSocket")
            )
        ) serverSocket = true
        if (!inetSocketAddress && (
                equalsAscii(bytes, start, end, "Ljava/net/InetSocketAddress;") ||
                    equalsAscii(bytes, start, end, "java.net.InetSocketAddress")
            )
        ) inetSocketAddress = true
        if (!inetAddress && (
                equalsAscii(bytes, start, end, "Ljava/net/InetAddress;") ||
                    equalsAscii(bytes, start, end, "java.net.InetAddress")
            )
        ) inetAddress = true
        if (!getLoopbackAddress && equalsAscii(bytes, start, end, "getLoopbackAddress")) {
            getLoopbackAddress = true
        }
        if (!loopbackMarker && (
                containsAscii(bytes, start, end, "localhost", ignoreCase = true) ||
                    containsAscii(bytes, start, end, "127.0.0.1") ||
                    equalsAscii(bytes, start, end, "::1") ||
                    containsAscii(bytes, start, end, "[::1]")
            )
        ) loopbackMarker = true
        if (!nanoHttpdMarker && (
                containsAscii(bytes, start, end, "nanohttpd", ignoreCase = true) ||
                    containsAscii(bytes, start, end, "fi/iki/elonen", ignoreCase = true)
            )
        ) nanoHttpdMarker = true

        return Signals(
            serverSocket = serverSocket,
            inetSocketAddress = inetSocketAddress,
            loopbackMarker = loopbackMarker,
            nanoHttpdMarker = nanoHttpdMarker,
            inetAddress = inetAddress,
            getLoopbackAddress = getLoopbackAddress,
        )
    }

    private fun readUInt(bytes: ByteArray, offset: Int): Long? {
        if (offset < 0 || offset.toLong() + UINT_BYTES > bytes.size.toLong()) return null
        return (bytes[offset].toLong() and 0xffL) or
            ((bytes[offset + 1].toLong() and 0xffL) shl 8) or
            ((bytes[offset + 2].toLong() and 0xffL) shl 16) or
            ((bytes[offset + 3].toLong() and 0xffL) shl 24)
    }

    private fun skipUleb128(bytes: ByteArray, offset: Int): Int? {
        var cursor = offset
        repeat(MAX_ULEB128_BYTES) {
            if (cursor >= bytes.size) return null
            val value = bytes[cursor++].toInt() and 0xff
            if (value and 0x80 == 0) return cursor
        }
        return null
    }

    private fun findTerminator(bytes: ByteArray, start: Int): Int? {
        for (index in start until bytes.size) if (bytes[index] == 0.toByte()) return index
        return null
    }

    private fun equalsAscii(bytes: ByteArray, start: Int, end: Int, expected: String): Boolean {
        if (end - start != expected.length) return false
        for (index in expected.indices) {
            if ((bytes[start + index].toInt() and 0xff) != expected[index].code) return false
        }
        return true
    }

    private fun containsAscii(
        bytes: ByteArray,
        start: Int,
        end: Int,
        expected: String,
        ignoreCase: Boolean = false,
    ): Boolean {
        if (expected.isEmpty() || end - start < expected.length) return false
        for (candidate in start..end - expected.length) {
            var matches = true
            for (index in expected.indices) {
                val actual = bytes[candidate + index].toInt() and 0xff
                val wanted = expected[index].code
                if (actual != wanted && (!ignoreCase || asciiLower(actual) != asciiLower(wanted))) {
                    matches = false
                    break
                }
            }
            if (matches) return true
        }
        return false
    }

    private fun asciiLower(value: Int): Int = if (value in 'A'.code..'Z'.code) value + 32 else value

    private const val DEX_HEADER_BYTES = 0x70L
    private const val UINT_BYTES = 4L
    private const val ENDIAN_TAG_OFFSET = 0x28
    private const val STRING_IDS_SIZE_OFFSET = 0x38
    private const val STRING_IDS_OFFSET_OFFSET = 0x3c
    private const val STANDARD_ENDIAN_TAG = 0x12345678L
    private const val MAX_STRING_IDS = 1_000_000L
    private const val MAX_ULEB128_BYTES = 5
    private const val MAX_STRING_SCAN_FACTOR = 2L
}

/** Fixed host-side execution gate; no provider-controlled value is returned. */
internal object AniyomiExtensionCapabilityPolicy {
    internal data class Rejection(val stage: String)

    fun rejection(operation: String, requiresLocalProxy: Boolean): Rejection? {
        if (!requiresLocalProxy) return null
        return when (operation) {
            "videos" -> Rejection("source_videos")
            "pages" -> Rejection("source_pages")
            else -> null
        }
    }
}
