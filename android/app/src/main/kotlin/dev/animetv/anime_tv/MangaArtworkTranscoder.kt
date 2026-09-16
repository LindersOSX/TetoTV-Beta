package dev.animetv.anime_tv

import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.os.Build
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/** Bounded Android-codec fallback for AVIF/HEIF cover artwork only. */
object MangaArtworkTranscoder {
    private const val MAX_ENCODED_BYTES = 20 * 1024 * 1024
    private const val MAX_OUTPUT_BYTES = 20 * 1024 * 1024
    private const val MAX_SOURCE_WIDTH = 8192
    private const val MAX_SOURCE_HEIGHT = 16384
    private const val MAX_SOURCE_PIXELS = 32L * 1024L * 1024L
    private const val TARGET_WIDTH = 1600
    private const val TARGET_HEIGHT = 2400
    private const val TARGET_PIXELS = 4L * 1024L * 1024L

    fun transcode(encoded: ByteArray): ByteArray? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P ||
            encoded.isEmpty() ||
            encoded.size > MAX_ENCODED_BYTES
        ) return null
        var bitmap: Bitmap? = null
        return try {
            val source = ImageDecoder.createSource(ByteBuffer.wrap(encoded))
            val decoded = ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                val width = info.size.width
                val height = info.size.height
                if (width <= 0 || height <= 0 ||
                    width > MAX_SOURCE_WIDTH || height > MAX_SOURCE_HEIGHT ||
                    width.toLong() * height.toLong() > MAX_SOURCE_PIXELS
                ) throw IllegalArgumentException("Unsafe artwork dimensions")

                val scale = min(
                    1.0,
                    min(
                        TARGET_WIDTH.toDouble() / width,
                        min(
                            TARGET_HEIGHT.toDouble() / height,
                            sqrt(TARGET_PIXELS.toDouble() / (width.toLong() * height.toLong())),
                        ),
                    ),
                )
                if (scale < 1.0) {
                    decoder.setTargetSize(
                        (width * scale).roundToInt().coerceAtLeast(1),
                        (height * scale).roundToInt().coerceAtLeast(1),
                    )
                }
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
            bitmap = decoded
            val output = ByteArrayOutputStream(512 * 1024)
            val format = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                Bitmap.CompressFormat.WEBP_LOSSY
            } else {
                @Suppress("DEPRECATION")
                Bitmap.CompressFormat.WEBP
            }
            if (!decoded.compress(format, 90, output)) return null
            output.toByteArray().takeIf { it.isNotEmpty() && it.size <= MAX_OUTPUT_BYTES }
        } catch (_: Throwable) {
            null
        } finally {
            bitmap?.recycle()
        }
    }
}
