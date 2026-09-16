package dev.animetv.anime_tv.aniyomi

import android.os.SystemClock
import java.net.URI
import java.security.SecureRandom
import java.util.Base64

/**
 * Process-local grants for manga images.
 *
 * URLs, provider headers and the extension cookie jar never cross the Flutter
 * channel. A random token identifies only one approved extension and expires
 * even while developer mode remains enabled.
 */
internal class AniyomiImageCapabilityStore(
    private val maximumEntries: Int = MAX_ENTRIES,
    private val ttlMs: Long = TTL_MS,
    private val now: () -> Long = SystemClock::elapsedRealtime,
    private val tokenFactory: () -> String = ::randomToken,
) {
    private val entries = LinkedHashMap<String, Grant>()

    init {
        require(maximumEntries in 1..MAX_ENTRIES)
        require(ttlMs in 1..TTL_MS)
    }

    /** Replace image transport details with opaque grants in a sanitized result. */
    @Synchronized
    fun protectResult(
        operation: String,
        result: Map<String, Any?>,
        extensionId: String,
        access: Long,
        cookieJar: AniyomiEphemeralCookieJar,
    ): Map<String, Any?> {
        if (!extensionId.startsWith("aniyomi:manga:")) return result
        return when (operation) {
            "pages" -> result + ("pages" to rows(result["pages"]).map { row ->
                val uri = imageUri(row["url"])
                val headers = imageHeaders(row["headers"])
                mapOf(
                    "index" to row["index"],
                    "imageCapability" to issue(
                        extensionId = extensionId,
                        uri = uri,
                        headers = headers,
                        cookieJar = cookieJar,
                        access = access,
                        artwork = false,
                    ),
                )
            })
            "search" -> result + ("items" to rows(result["items"]).map { row ->
                protectCover(row, extensionId, access, cookieJar)
            })
            "details" -> {
                val item = result["item"] as? Map<*, *> ?: throw IllegalArgumentException("invalid_item")
                result + ("item" to protectCover(item, extensionId, access, cookieJar))
            }
            else -> result
        }
    }

    @Synchronized
    fun resolve(extensionId: String, token: String): Grant {
        require(validExtensionId(extensionId) && TOKEN_PATTERN.matches(token)) {
            INVALID_CAPABILITY
        }
        purgeExpired()
        val grant = entries[token]
        require(grant != null && grant.extensionId == extensionId && grant.expiresAt > now()) {
            INVALID_CAPABILITY
        }
        return grant
    }

    @Synchronized
    fun clear(extensionId: String? = null) {
        if (extensionId == null) entries.clear()
        else entries.entries.removeAll { it.value.extensionId == extensionId }
    }

    @Synchronized
    internal fun sizeForTest(): Int {
        purgeExpired()
        return entries.size
    }

    private fun protectCover(
        input: Map<*, *>,
        extensionId: String,
        access: Long,
        cookieJar: AniyomiEphemeralCookieJar,
    ): Map<String, Any?> {
        val result = input.entries.associate { (key, value) -> key as String to value }.toMutableMap()
        val rawUrl = result.remove("thumbnailUrl")
        val rawHeaders = result.remove("thumbnailHeaders")
        if (rawUrl != null) {
            result["imageCapability"] = issue(
                extensionId = extensionId,
                uri = imageUri(rawUrl),
                headers = imageHeaders(rawHeaders),
                cookieJar = cookieJar,
                access = access,
                artwork = true,
            )
        }
        return result
    }

    private fun issue(
        extensionId: String,
        uri: URI,
        headers: Map<String, String>,
        cookieJar: AniyomiEphemeralCookieJar,
        access: Long,
        artwork: Boolean,
    ): String {
        require(validExtensionId(extensionId)) { INVALID_CAPABILITY }
        purgeExpired()
        while (entries.size >= maximumEntries) {
            entries.remove(entries.keys.first())
        }
        repeat(8) {
            val token = tokenFactory()
            require(TOKEN_PATTERN.matches(token)) { "invalid_capability_token" }
            if (token !in entries) {
                entries[token] = Grant(
                    extensionId = extensionId,
                    uri = uri,
                    headers = headers,
                    cookieJar = cookieJar,
                    access = access,
                    expiresAt = safeExpiry(now(), ttlMs),
                    artwork = artwork,
                )
                return token
            }
        }
        throw IllegalStateException("image_capability_unavailable")
    }

    private fun purgeExpired() {
        val clock = now()
        entries.entries.removeAll { it.value.expiresAt <= clock }
    }

    private fun imageUri(value: Any?): URI =
        AniyomiPolicy.publicHttps(value as? String ?: throw IllegalArgumentException("invalid_image_url"))

    private fun imageHeaders(value: Any?): Map<String, String> {
        if (value == null) return emptyMap()
        val input = value as? Map<*, *> ?: throw IllegalArgumentException("invalid_image_headers")
        val strings = input.entries.associate { (key, header) ->
            (key as? String ?: throw IllegalArgumentException("invalid_image_headers")) to
                (header as? String ?: throw IllegalArgumentException("invalid_image_headers"))
        }
        return AniyomiImageHeaderPolicy.headers(strings)
    }

    private fun rows(value: Any?): List<Map<*, *>> =
        (value as? List<*>)?.map {
            it as? Map<*, *> ?: throw IllegalArgumentException("invalid_image_row")
        } ?: throw IllegalArgumentException("invalid_image_rows")

    internal data class Grant(
        val extensionId: String,
        val uri: URI,
        val headers: Map<String, String>,
        val cookieJar: AniyomiEphemeralCookieJar,
        val access: Long,
        val expiresAt: Long,
        val artwork: Boolean,
    )

    internal companion object {
        const val MAX_ENTRIES = 4096
        // Long enough for a deliberate reading session, still finite and
        // always cut short by developer-mode disable/revoke/host close.
        const val TTL_MS = 2 * 60 * 60 * 1000L
        const val INVALID_CAPABILITY = "image_capability_invalid"
        private val TOKEN_PATTERN = Regex("[A-Za-z0-9_-]{43}")

        private fun validExtensionId(value: String): Boolean =
            value.length in 17..240 && value.startsWith("aniyomi:manga:")

        private fun safeExpiry(start: Long, ttl: Long): Long =
            if (start > Long.MAX_VALUE - ttl) Long.MAX_VALUE else start + ttl

        private fun randomToken(): String {
            val bytes = ByteArray(32)
            SecureRandom().nextBytes(bytes)
            return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
        }
    }
}

/** Headers that may be retained only inside an opaque image grant. */
internal object AniyomiImageHeaderPolicy {
    private val allowed = setOf(
        "authorization", "cookie", "user-agent", "referer", "origin",
        "accept", "accept-language", "range",
    )

    fun headers(input: Map<String, String>): Map<String, String> {
        require(input.size <= 12 && input.entries.sumOf {
            it.key.toByteArray().size + it.value.toByteArray().size
        } <= 8192) { "image_headers_too_large" }
        return input.entries.associate { (key, value) ->
            val lower = key.lowercase()
            require(key.length in 1..64 && key.all {
                it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '-' || it == '_'
            } && lower in allowed) { "image_header_not_permitted" }
            require(value.length <= 2048 && value.none { it < ' ' || it == '\u007f' }) {
                "invalid_image_header"
            }
            if (lower == "referer" || lower == "origin") AniyomiPolicy.publicHttps(value)
            key to value
        }
    }
}
