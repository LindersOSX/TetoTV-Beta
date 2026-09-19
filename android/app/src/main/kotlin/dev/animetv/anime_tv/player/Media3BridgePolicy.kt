package dev.animetv.anime_tv.player

import java.net.URI
import java.util.Locale

/** Pure validation shared by the platform bridge and JVM contract tests. */
internal object Media3BridgePolicy {
    fun exceptionKind(error: Exception): String = when {
        error.javaClass.name == "android.os.NetworkOnMainThreadException" -> "network_on_main_thread"
        error is java.util.ConcurrentModificationException -> "concurrent_modification"
        error is SecurityException -> "security"
        error is IllegalStateException -> "illegal_state"
        else -> "other"
    }
    const val MAX_SIDECAR_BYTES = 2 * 1024 * 1024
    const val MAX_SIDECARS = 32
    const val MAX_AUDIO_SIDECARS = 8
    const val MAX_PLAYERS = 2
    // Keep ExoPlayer's main-thread blocking wait short. An asynchronous owned
    // playback-thread poll supplies the rest of the bounded safety window.
    const val RELEASE_TIMEOUT_MS = 1_000L
    const val RELEASE_COMPLETION_GRACE_MS = 3_000L
    const val RELEASE_POLL_INTERVAL_MS = 50L
    const val RELEASE_TOTAL_TIMEOUT_MS = RELEASE_TIMEOUT_MS + RELEASE_COMPLETION_GRACE_MS
    // A timed-out Flutter call receives its bounded answer at four seconds,
    // while native cleanup gets a longer bounded background window. A later
    // create also sweeps completed sessions in case the thread ends afterward.
    const val RELEASE_AUTOMATIC_REAP_WINDOW_MS = 30_000L
    const val RELEASE_AUTOMATIC_REAP_INTERVAL_MS = 250L
    const val SCREENSHOT_MAX_DIMENSION = 480
    const val SCREENSHOT_MAX_BYTES = 256 * 1024
    private val headerName = Regex("^[!#$%&'*+.^_`|~0-9A-Za-z-]{1,128}$")

    fun surfaceType(raw: Any?): String = when (raw) {
        null, "texture" -> "texture"
        "surface" -> "surface"
        else -> throw IllegalArgumentException("invalid_surface_type")
    }

    fun screenshotSize(width: Int, height: Int): Pair<Int, Int>? {
        if (width <= 0 || height <= 0) return null
        val scale = minOf(1.0, SCREENSHOT_MAX_DIMENSION.toDouble() / maxOf(width, height))
        return maxOf(1, (width * scale).toInt()) to maxOf(1, (height * scale).toInt())
    }

    fun supportedUri(value: String): Boolean {
        if (value.isBlank() || value.length > 16_384 || value.any { it.code < 32 }) return false
        return runCatching {
            val uri = URI(value)
            when (uri.scheme?.lowercase(Locale.ROOT)) {
                "http", "https" -> !uri.host.isNullOrBlank() && uri.rawUserInfo == null
                "file" -> !uri.path.isNullOrBlank() && uri.host.isNullOrBlank()
                "content" -> !uri.authority.isNullOrBlank()
                else -> false
            }
        }.getOrDefault(false)
    }

    fun ownedLoopbackAudioUri(value: String): Boolean {
        if (value.isBlank() || value.length > 16_384 || value.any { it.code < 32 }) return false
        return runCatching {
            val uri = URI(value)
            uri.scheme.equals("http", true) && uri.host == "127.0.0.1" &&
                uri.port in 1..65_535 && uri.rawUserInfo == null &&
                !uri.path.isNullOrBlank() && uri.path != "/"
        }.getOrDefault(false)
    }

    fun externalAudioMime(value: String?): String? {
        val mime = value?.lowercase(Locale.ROOT)?.substringBefore(';')?.trim()
        return mime?.takeIf {
            it.startsWith("audio/") || it in setOf(
                "application/vnd.apple.mpegurl",
                "application/x-mpegurl",
                "application/octet-stream",
            )
        }
    }

    // The app-owned HLS proxy uses the registered vendor MIME; Media3 uses
    // x-mpegURL internally. Normalize both before selecting a MediaSource.
    fun playbackMime(value: String?): String? {
        val mime = value?.lowercase(Locale.ROOT)?.substringBefore(';')?.trim() ?: return null
        return when (mime) {
            "application/vnd.apple.mpegurl", "application/x-mpegurl" -> "application/x-mpegURL"
            "application/dash+xml", "video/mp4", "video/webm", "video/x-matroska",
            "video/mp2t", "application/octet-stream" -> mime
            else -> throw IllegalArgumentException("invalid_media_mime")
        }
    }

    fun normalizedExternalAudioMime(value: String?): String? = externalAudioMime(value)?.let {
        if (it == "application/vnd.apple.mpegurl" || it == "application/x-mpegurl") "application/x-mpegURL" else it
    }

    fun mergedChildIndex(trackGroupId: String): Int? {
        if (trackGroupId.length > 256) return null
        return Regex("^([0-9]{1,2}):").find(trackGroupId)
            ?.groupValues?.get(1)?.toIntOrNull()
    }

    fun shouldRetryPrimaryWithoutExternalAudio(
        externalAudioCount: Int,
        alreadyRetried: Boolean,
    ): Boolean = externalAudioCount in 1..MAX_AUDIO_SIDECARS && !alreadyRetried

    fun sameOrigin(first: String, second: String): Boolean = runCatching {
        val a = URI(first)
        val b = URI(second)
        fun port(uri: URI) = if (uri.port >= 0) uri.port else if (uri.scheme.equals("https", true)) 443 else 80
        a.scheme?.lowercase(Locale.ROOT) in setOf("https", "http") &&
            a.scheme.equals(b.scheme, true) && a.host != null &&
            a.host.equals(b.host, true) && port(a) == port(b) &&
            a.rawUserInfo == null && b.rawUserInfo == null
    }.getOrDefault(false)

    fun headers(raw: Any?): Map<String, String> {
        if (raw == null) return emptyMap()
        require(raw is Map<*, *> && raw.size <= 64) { "invalid_headers" }
        val result = linkedMapOf<String, String>()
        for ((key, value) in raw) {
            require(key is String && headerName.matches(key)) { "invalid_headers" }
            require(value is String && value.length <= 8_192 && value.all { it.code in 32..126 }) { "invalid_headers" }
            require(key.lowercase(Locale.ROOT) !in setOf("host", "connection", "content-length", "transfer-encoding")) { "invalid_headers" }
            result[key] = value
        }
        require(result.values.sumOf(String::length) <= 32_768) { "invalid_headers" }
        return result
    }

    fun number(raw: Any?, minimum: Double, maximum: Double): Double? =
        (raw as? Number)?.toDouble()?.takeIf { it.isFinite() && it in minimum..maximum }

    fun integer(raw: Any?, minimum: Long = 0, maximum: Long = 604_800_000): Long? {
        val number = number(raw, minimum.toDouble(), maximum.toDouble()) ?: return null
        return number.toLong().takeIf { it.toDouble() == number }
    }

    fun unsupportedOptions(raw: Map<*, *>): List<String> {
        val allowed = setOf(
            "fit", "subtitleSize", "subtitlePosition", "subtitleBackground",
            "subtitleColor", "subtitleBold", "audioLanguage", "subtitleLanguage",
            "audioDelayMs", "subtitleDelayMs",
        )
        return raw.keys.filterIsInstance<String>().filter {
            it !in allowed || (it in setOf("audioDelayMs", "subtitleDelayMs") && raw[it] != 0 && raw[it] != 0.0)
        }
    }

    fun validTrackId(value: String): Boolean =
        Regex("^(?:audio|subtitle)/g[0-9]{1,9}/t[0-9]{1,3}$").matches(value) ||
            Regex("^sidecar:[0-9]{1,3}$").matches(value)

    fun sidecarTrackId(
        formatId: String?,
        registeredIds: List<String>,
        primaryWrappedForExternalAudio: Boolean = false,
    ): String? {
        if (formatId == null || formatId.length > 32) return null
        // DefaultMediaSourceFactory merges main media at child zero followed
        // by configured subtitles. Our optional external-audio merge then
        // wraps that complete primary source at outer child zero. Validate the
        // exact known path; never match an arbitrary suffix from an embedded
        // or provider-controlled track identifier.
        for ((index, id) in registeredIds.take(MAX_SIDECARS).withIndex()) {
            val inner = "${index + 1}:$id"
            val expected = if (primaryWrappedForExternalAudio) "0:$inner" else inner
            if (formatId == expected) return id
        }
        return null
    }

    fun endPositionMs(raw: Any?, startMs: Long): Long? {
        if (raw == null) return null
        val endMs = requireNotNull(integer(raw, 1)) { "invalid_end_position" }
        require(endMs > startMs) { "invalid_end_position" }
        return endMs
    }

    fun subtitleMime(bytes: ByteArray): String {
        require(bytes.isNotEmpty() && bytes.size <= MAX_SIDECAR_BYTES)
        // Inspect only a small prefix. Data can be a BOM-prefixed ASS file or
        // an opaque provider response with no meaningful filename extension.
        val prefix = bytes.copyOfRange(0, minOf(bytes.size, 4_096))
            .toString(Charsets.UTF_8).trimStart('\uFEFF', ' ', '\t', '\r', '\n')
        return when {
            prefix.startsWith("WEBVTT") -> "text/vtt"
            Regex("(?im)^\\[(?:Script Info|V4\\+? Styles|Events)]").containsMatchIn(prefix) -> "text/x-ssa"
            Regex("(?is)^(?:<\\?xml[^>]*>\\s*)?<tt(?:\\s|>)").containsMatchIn(prefix) -> "application/ttml+xml"
            else -> "application/x-subrip"
        }
    }

    fun chapterPositionSeconds(startMs: Long, periodPositionInWindowMs: Long): Double? {
        if (startMs !in 0..604_800_000L || periodPositionInWindowMs !in -604_800_000L..604_800_000L) return null
        val position = startMs + periodPositionInWindowMs
        return position.takeIf { it in 0..604_800_000L }?.div(1_000.0)
    }

    fun safeDecoderName(value: String): String? =
        value.takeIf { Regex("^[A-Za-z0-9._-]{1,160}$").matches(it) }

    fun errorCode(value: String): String = value.takeIf {
        Regex("^ERROR_CODE_[A-Z0-9_]{1,80}$").matches(it)
    } ?: "ERROR_CODE_UNSPECIFIED"

    fun codec(mimeType: String?): String? = when (mimeType) {
        "video/avc" -> "h264"
        "video/hevc" -> "hevc"
        "video/av01" -> "av1"
        "video/x-vnd.on2.vp9" -> "vp9"
        "video/x-vnd.on2.vp8" -> "vp8"
        "video/mpeg2" -> "mpeg2video"
        "video/mp4v-es" -> "mpeg4"
        "audio/mp4a-latm" -> "aac"
        "audio/ac3" -> "ac3"
        "audio/eac3", "audio/eac3-joc" -> "eac3"
        "audio/vnd.dts", "audio/vnd.dts.hd" -> "dts"
        "audio/true-hd" -> "truehd"
        "audio/opus" -> "opus"
        "audio/vorbis" -> "vorbis"
        "audio/flac" -> "flac"
        "audio/alac" -> "alac"
        "audio/mpeg" -> "mp3"
        "audio/raw" -> "pcm"
        else -> null
    }
}

internal enum class Media3ReleasePollAction { COMPLETE, WAIT, TIMED_OUT }

internal enum class Media3ReleaseReapAction { REAP, WAIT, STOP }

/** Pure bounded-poll policy for the owned Media3 playback thread. */
internal fun media3ReleasePollAction(
    playbackThreadAlive: Boolean,
    elapsedMs: Long,
): Media3ReleasePollAction = when {
    !playbackThreadAlive -> Media3ReleasePollAction.COMPLETE
    elapsedMs >= Media3BridgePolicy.RELEASE_COMPLETION_GRACE_MS ->
        Media3ReleasePollAction.TIMED_OUT
    else -> Media3ReleasePollAction.WAIT
}

/** Pure policy for the bounded native follow-up after Flutter's wait expires. */
internal fun media3ReleaseReapAction(
    playbackThreadAlive: Boolean,
    elapsedMs: Long,
): Media3ReleaseReapAction = when {
    !playbackThreadAlive -> Media3ReleaseReapAction.REAP
    elapsedMs >= Media3BridgePolicy.RELEASE_AUTOMATIC_REAP_WINDOW_MS ->
        Media3ReleaseReapAction.STOP
    else -> Media3ReleaseReapAction.WAIT
}

/**
 * Tracks only playback threads owned by each default ExoPlayer instance. A
 * new player may be created once every tracked thread is demonstrably dead.
 */
internal class Media3PlaybackThreadRegistry<T>(
    private val isAlive: (T) -> Boolean,
) {
    private val tracked = linkedSetOf<T>()

    @Synchronized
    fun track(value: T) {
        tracked += value
    }

    @Synchronized
    fun allReleased(): Boolean {
        tracked.removeAll { !isAlive(it) }
        return tracked.isEmpty()
    }
}

/** Open IDs alone can repeat during a decoder restart; tickets never do. */
internal class Media3CallbackEpoch {
    class Ticket internal constructor(val generation: Long, val openId: Long)
    private var generation = 0L
    private var current: Ticket? = null
    fun begin(openId: Long): Ticket = Ticket(++generation, openId).also { current = it }
    fun invalidate() { generation++; current = null }
    fun accepts(ticket: Ticket): Boolean = current === ticket
}

/** A detached/disposed capture replies with null once, even if PixelCopy finishes later. */
internal class Media3ScreenshotResult(reply: (ByteArray?) -> Unit) {
    private var reply: ((ByteArray?) -> Unit)? = reply
    val isPending: Boolean get() = reply != null

    fun complete(bytes: ByteArray?) {
        val callback = reply ?: return
        reply = null
        callback(bytes)
    }
}
