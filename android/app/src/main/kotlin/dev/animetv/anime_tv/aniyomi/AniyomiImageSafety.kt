package dev.animetv.anime_tv.aniyomi

/** Header-only validation before provider bytes cross into Flutter's decoder. */
internal object AniyomiImageSafety {
    private const val MAX_WIDTH = 8192
    private const val MAX_HEIGHT = 16384
    private const val MAX_PIXELS = 32L * 1024L * 1024L

    fun inspect(bytes: ByteArray) {
        val (width, height) = when {
            matches(bytes, 0, 0xff, 0xd8, 0xff) -> jpegDimensions(bytes)
            matches(bytes, 0, 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a) -> pngDimensions(bytes)
            matches(bytes, 0, 0x47, 0x49, 0x46, 0x38, 0x37, 0x61) ||
                matches(bytes, 0, 0x47, 0x49, 0x46, 0x38, 0x39, 0x61) -> gifDimensions(bytes)
            matches(bytes, 0, 0x52, 0x49, 0x46, 0x46) &&
                matches(bytes, 8, 0x57, 0x45, 0x42, 0x50) -> webpDimensions(bytes)
            else -> throw IllegalArgumentException("image_not_supported")
        }
        require(width > 0 && height > 0) { "image_malformed" }
        require(width <= MAX_WIDTH && height <= MAX_HEIGHT && width.toLong() * height <= MAX_PIXELS) {
            "image_dimensions_exceeded"
        }
    }

    fun isIsoBmffImage(bytes: ByteArray): Boolean {
        if (bytes.size < 16 || !matches(bytes, 4, 0x66, 0x74, 0x79, 0x70)) return false
        val size = uint32be(bytes, 0)
        if (size !in 16..256 || size > bytes.size || size % 4 != 0) return false
        for (offset in 8 until size step 4) {
            if (offset == 12) continue
            val brand = String(bytes, offset, 4, Charsets.US_ASCII)
            if (brand in ISO_IMAGE_BRANDS) return true
        }
        return false
    }

    private fun pngDimensions(bytes: ByteArray): Pair<Int, Int> {
        require(bytes.size >= 24 && uint32be(bytes, 8) == 13 && matches(bytes, 12, 0x49, 0x48, 0x44, 0x52)) {
            "image_malformed"
        }
        return uint32be(bytes, 16) to uint32be(bytes, 20)
    }

    private fun gifDimensions(bytes: ByteArray): Pair<Int, Int> {
        require(bytes.size >= 10) { "image_malformed" }
        return uint16le(bytes, 6) to uint16le(bytes, 8)
    }

    private fun jpegDimensions(bytes: ByteArray): Pair<Int, Int> {
        var offset = 2
        while (offset < bytes.size) {
            require(u8(bytes[offset]) == 0xff) { "image_malformed" }
            while (offset < bytes.size && u8(bytes[offset]) == 0xff) offset++
            if (offset >= bytes.size) break
            val marker = u8(bytes[offset++])
            require(marker != 0) { "image_malformed" }
            if (marker == 0xd8 || marker == 0x01 || marker in 0xd0..0xd7) continue
            if (marker == 0xd9 || marker == 0xda) break
            require(offset + 2 <= bytes.size) { "image_malformed" }
            val length = uint16be(bytes, offset)
            require(length >= 2 && offset + length <= bytes.size) { "image_malformed" }
            if (marker in JPEG_SOF) {
                require(length >= 7) { "image_malformed" }
                return uint16be(bytes, offset + 5) to uint16be(bytes, offset + 3)
            }
            offset += length
        }
        throw IllegalArgumentException("image_malformed")
    }

    private fun webpDimensions(bytes: ByteArray): Pair<Int, Int> {
        require(bytes.size >= 20) { "image_malformed" }
        val declared = uint32le(bytes, 4).toLong() + 8L
        require(declared in 20..bytes.size.toLong()) { "image_malformed" }
        var offset = 12
        while (offset + 8 <= declared) {
            val chunkSize = uint32le(bytes, offset + 4).toLong()
            val data = offset + 8
            require(chunkSize <= declared - data) { "image_malformed" }
            when {
                matches(bytes, offset, 0x56, 0x50, 0x38, 0x58) -> {
                    require(chunkSize >= 10) { "image_malformed" }
                    return (1 + uint24le(bytes, data + 4)) to (1 + uint24le(bytes, data + 7))
                }
                matches(bytes, offset, 0x56, 0x50, 0x38, 0x4c) -> {
                    require(chunkSize >= 5 && u8(bytes[data]) == 0x2f) { "image_malformed" }
                    val b1 = u8(bytes[data + 1]); val b2 = u8(bytes[data + 2])
                    val b3 = u8(bytes[data + 3]); val b4 = u8(bytes[data + 4])
                    return (1 + b1 + ((b2 and 0x3f) shl 8)) to
                        (1 + (b2 shr 6) + (b3 shl 2) + ((b4 and 0x0f) shl 10))
                }
                matches(bytes, offset, 0x56, 0x50, 0x38, 0x20) -> {
                    require(chunkSize >= 10 && matches(bytes, data + 3, 0x9d, 0x01, 0x2a)) { "image_malformed" }
                    return (uint16le(bytes, data + 6) and 0x3fff) to (uint16le(bytes, data + 8) and 0x3fff)
                }
            }
            val padded = chunkSize + (chunkSize and 1L)
            require(padded <= declared - data) { "image_malformed" }
            offset = (data + padded).toInt()
        }
        throw IllegalArgumentException("image_malformed")
    }

    private fun matches(bytes: ByteArray, offset: Int, vararg expected: Int): Boolean =
        offset >= 0 && offset + expected.size <= bytes.size && expected.indices.all {
            u8(bytes[offset + it]) == expected[it]
        }

    private fun u8(value: Byte): Int = value.toInt() and 0xff
    private fun uint16be(bytes: ByteArray, offset: Int): Int =
        (u8(bytes[offset]) shl 8) or u8(bytes[offset + 1])
    private fun uint16le(bytes: ByteArray, offset: Int): Int =
        u8(bytes[offset]) or (u8(bytes[offset + 1]) shl 8)
    private fun uint24le(bytes: ByteArray, offset: Int): Int =
        u8(bytes[offset]) or (u8(bytes[offset + 1]) shl 8) or (u8(bytes[offset + 2]) shl 16)
    private fun uint32be(bytes: ByteArray, offset: Int): Int =
        (u8(bytes[offset]) shl 24) or (u8(bytes[offset + 1]) shl 16) or
            (u8(bytes[offset + 2]) shl 8) or u8(bytes[offset + 3])
    private fun uint32le(bytes: ByteArray, offset: Int): Int =
        u8(bytes[offset]) or (u8(bytes[offset + 1]) shl 8) or
            (u8(bytes[offset + 2]) shl 16) or (u8(bytes[offset + 3]) shl 24)

    private val JPEG_SOF = setOf(0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf)
    private val ISO_IMAGE_BRANDS = setOf("avif", "avis", "heic", "heix", "hevc", "hevx", "mif1", "msf1")
}
