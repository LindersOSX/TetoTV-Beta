package aniyomi.lib.m3u8server

import java.util.concurrent.atomic.AtomicInteger
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient

/**
 * Socket-free compatibility bridge for the common Aniyomi M3U8 helper.
 *
 * Extension workers run under an isolated UID and are destroyed after each
 * request, so a NanoHTTPD listener created inside one can neither bind safely
 * nor outlive video discovery. This ABI-compatible host class keeps the
 * extension lifecycle intact while returning the original public-looking HTTPS
 * target. TetoTV's trusted `WebPlaybackProxy` then owns DNS pinning, redirects,
 * manifest rewriting, headers, limits and loopback lifetime.
 *
 * Keep this class narrow and socket-free. It is selected by exact class name;
 * no other `aniyomi.lib` implementation is shared with extension code.
 */
class M3u8ServerManager(
    @Suppress("UNUSED_PARAMETER") client: OkHttpClient,
    @Suppress("UNUSED_PARAMETER") fallbackClient: OkHttpClient? = null,
) {
    @Volatile
    private var ready = false

    @Synchronized
    fun startServer(port: Int = 0) {
        require(port in 0..65535) { "invalid_port" }
        ready = true
    }

    @Synchronized
    fun stopServer() {
        ready = false
    }

    fun isRunning(): Boolean = ready

    /** There is deliberately no extension-owned loopback listener. */
    fun getServerUrl(): String? = null

    fun processM3u8Url(
        m3u8Url: String,
        referer: String? = null,
        userAgent: String? = null,
    ): String? {
        if (!ready || m3u8Url.length !in 1..8192) return null
        val target = m3u8Url.toHttpUrlOrNull() ?: return null
        if (!target.isHttps || target.username.isNotEmpty() || target.password.isNotEmpty()) return null
        if (referer != null) {
            if (referer.length > 2048 || hasControls(referer)) return null
            val referrerTarget = referer.toHttpUrlOrNull() ?: return null
            if (!referrerTarget.isHttps || referrerTarget.username.isNotEmpty() || referrerTarget.password.isNotEmpty()) {
                return null
            }
        }
        if (userAgent != null && (userAgent.length > 1024 || hasControls(userAgent))) return null
        bridgedCount.incrementAndGet()
        return target.toString()
    }

    /** Segment transforms are never executed inside the untrusted worker. */
    @Suppress("UNUSED_PARAMETER")
    suspend fun processSegmentUrl(
        segmentUrl: String,
        headers: Map<String, String> = emptyMap(),
    ): ByteArray? = null

    fun getServerInfo(): String = if (ready) {
        "TetoTV host-owned M3U8 bridge is ready"
    } else {
        "TetoTV host-owned M3U8 bridge is stopped"
    }

    private fun hasControls(value: String): Boolean = value.any { it < ' ' || it == '\u007f' }

    companion object {
        private val bridgedCount = AtomicInteger()

        internal fun resetBridgeDiagnostics() {
            bridgedCount.set(0)
        }

        internal fun consumeBridgeCount(): Int = bridgedCount.getAndSet(0).coerceAtLeast(0)
    }
}
