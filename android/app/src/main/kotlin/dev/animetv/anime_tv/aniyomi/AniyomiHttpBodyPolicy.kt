package dev.animetv.anime_tv.aniyomi

import java.io.InputStream
import java.io.OutputStream

/** Bounds decoded bytes, including responses without a trustworthy Content-Length. */
internal object AniyomiHttpBodyPolicy {
    fun copy(
        input: InputStream,
        output: OutputStream,
        declaredLength: Long,
        maximum: Int = AniyomiPolicy.MAX_HTTP_BYTES,
        checkAllowed: () -> Unit,
        observeSize: (Long) -> Unit = {},
    ): Int {
        require(maximum >= 0)
        checkAllowed()
        observeSize(declaredLength)
        require(declaredLength <= maximum) { "http_response_too_large" }
        var total = 0
        val buffer = ByteArray(8192)
        while (true) {
            checkAllowed()
            // Read at most one byte beyond the limit, even for a compressed or
            // chunked response. Never buffer an unbounded body before checking.
            val count = input.read(buffer, 0, minOf(buffer.size, maximum - total + 1))
            if (count < 0) break
            if (count == 0) continue
            checkAllowed()
            observeSize(total.toLong() + count)
            require(count <= maximum - total) { "http_response_too_large" }
            output.write(buffer, 0, count)
            total += count
        }
        checkAllowed()
        observeSize(total.toLong())
        return total
    }
}
