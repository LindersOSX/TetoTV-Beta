package dev.animetv.anime_tv.aniyomi

import java.io.IOException
import java.net.URI
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import org.json.JSONException
import org.json.JSONObject

/** Pure validation for the untrusted request envelope received from the worker. */
internal object AniyomiHttpBrokerInputPolicy {
    const val MAX_REDIRECTS = 3

    private val blockedHeaders = setOf(
        "authorization",
        "proxy-authorization",
        "cookie",
        "cookie2",
        "set-cookie",
        "host",
        "content-length",
        "transfer-encoding",
        "connection",
        "proxy-connection",
        "keep-alive",
        "upgrade",
        "expect",
        "te",
        "trailer",
        "accept-encoding",
        "forwarded",
        "via",
        "x-forwarded-for",
        "x-forwarded-host",
        "x-forwarded-proto",
        "x-real-ip",
    )

    fun headers(input: JSONObject): Map<String, String> {
        require(input.toString().toByteArray().size <= 8192 && input.length() <= 16) {
            "http_headers_too_large"
        }
        return headers(input.keys().asSequence().associateWith(input::getString))
    }

    internal fun headers(input: Map<String, String>): Map<String, String> {
        require(input.size <= 16 && input.entries.sumOf { it.key.toByteArray().size + it.value.toByteArray().size } <= 8192) {
            "http_headers_too_large"
        }
        val safe = linkedMapOf<String, String>()
        input.forEach { (key, value) ->
            val lower = key.lowercase()
            require(key.length in 1..64 && key.all {
                it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '-' || it == '_'
            }) {
                "invalid_http_header"
            }
            require(lower !in blockedHeaders && !lower.startsWith("proxy-") && !lower.startsWith("sec-websocket-")) {
                "http_header_not_permitted"
            }
            require(value.length <= 2048 && value.none { it < ' ' || it == '\u007f' }) {
                "invalid_http_header"
            }
            // Some providers concatenate a search title into Referer without
            // escaping spaces. Encode that one character, then apply the same
            // strict URL policy: do not let a forgiving URL parser repair an
            // authority, credentials, control characters, or a backslash.
            val normalized = if (lower == "referer") value.replace(" ", "%20") else value
            require(normalized.length <= 2048) { "invalid_http_header" }
            if (lower == "referer" || lower == "origin") AniyomiPolicy.publicHttps(normalized)
            safe[key] = normalized
        }
        return safe
    }

    fun redirectedMethod(statusCode: Int, currentMethod: String): String =
        if (currentMethod == "POST" && statusCode in setOf(301, 302, 303)) "GET" else currentMethod

    /**
     * Older workers did not send redirect preferences, so the defaults retain
     * the broker's previous HTTPS-to-HTTPS redirect behavior. New workers send
     * both values explicitly from the extension's OkHttp client.
     */
    fun redirectPreferences(input: JSONObject): AniyomiRedirectPreferences = redirectPreferences(
        input.keys().asSequence().associateWith(input::get),
    )

    internal fun redirectPreferences(input: Map<String, Any?>): AniyomiRedirectPreferences =
        AniyomiRedirectPreferences(
            followRedirects = strictBoolean(input, "followRedirects", default = true),
            followSslRedirects = strictBoolean(input, "followSslRedirects", default = false),
        )

    /** Resolve a Location without ever allowing a non-HTTPS or private literal target. */
    fun redirectDecision(
        current: URI,
        location: String,
        statusCode: Int,
        followedRedirects: Int,
        preferences: AniyomiRedirectPreferences,
    ): AniyomiRedirectDecision {
        require(statusCode in REDIRECT_CODES && location.length in 1..4096 &&
            location.none { it <= ' ' || it == '\\' }) { "invalid_redirect" }
        val target = try {
            AniyomiPolicy.publicHttps(current.resolve(location).toASCIIString())
        } catch (error: IllegalArgumentException) {
            // Preserve policy-denial reasons from publicHttps while normalizing
            // malformed URI resolution to one fixed reason.
            if (error.message in REDIRECT_POLICY_REASONS) throw error
            throw IllegalArgumentException("invalid_redirect")
        }
        val changesScheme = !current.scheme.equals(target.scheme, ignoreCase = true)
        val follow = preferences.followRedirects &&
            (!changesScheme || preferences.followSslRedirects)
        if (follow) require(followedRedirects < MAX_REDIRECTS) { "http_redirect_limit" }
        return AniyomiRedirectDecision(target, follow)
    }

    private fun strictBoolean(input: Map<String, Any?>, name: String, default: Boolean): Boolean {
        if (name !in input) return default
        val value = input[name]
        require(value is Boolean) { "invalid_http_option" }
        return value
    }

    private val REDIRECT_CODES = setOf(301, 302, 303, 307, 308)
    private val REDIRECT_POLICY_REASONS = setOf(
        "invalid_https_url",
        "invalid_https_host",
        "public_https_required",
        "https_port_not_allowed",
        "private_host_blocked",
    )
}

internal data class AniyomiRedirectPreferences(
    val followRedirects: Boolean,
    val followSslRedirects: Boolean,
)

internal data class AniyomiRedirectDecision(
    val location: URI,
    val follow: Boolean,
)

/** Atomic per-invocation budget shared by all parallel broker calls. */
internal class AniyomiHttpRequestBudget(private val maximum: Int) {
    private val used = AtomicInteger()
    private val rejected = AtomicBoolean()

    val usedCount: Int get() = used.get()
    val limitHit: Boolean get() = rejected.get()

    init {
        require(maximum > 0)
    }

    fun claim() {
        while (true) {
            val current = used.get()
            if (current >= maximum) {
                rejected.set(true)
                throw IllegalArgumentException("http_request_limit")
            }
            if (used.compareAndSet(current, current + 1)) return
        }
    }
}

/** Host-owned, operation-local history; never retains provider data or exception text. */
internal class AniyomiHttpDiagnostics(private val budget: AniyomiHttpRequestBudget) {
    private data class Failures(val count: Int = 0, val last: String = "none")
    private val failures = AtomicReference(Failures())

    fun recordFailure(code: String) {
        val category = AniyomiHttpBrokerFailurePolicy.failureName(code)
        failures.updateAndGet { previous ->
            Failures((previous.count + 1).coerceAtMost(64), category)
        }
    }

    fun snapshot(): Map<String, Any> {
        val history = failures.get()
        return mapOf(
            "requestCount" to budget.usedCount.coerceIn(0, AniyomiPolicy.MAX_HTTP_REQUESTS),
            "requestLimit" to AniyomiPolicy.MAX_HTTP_REQUESTS,
            "failureCount" to history.count,
            "requestLimitHit" to budget.limitHit,
            "lastFailure" to history.last,
        )
    }

    // Called only after normal worker-result sanitization and image protection.
    // Right-hand replacement prevents even a forged worker field from winning.
    fun attachTo(result: Map<String, Any?>): Map<String, Any?> =
        result + ("httpDiagnostics" to snapshot())
}

/**
 * Small in-memory jar owned by one approved extension while developer mode is active. It receives
 * only cookies issued by public HTTPS responses made by this broker, is never
 * persisted, and cannot read or share TetoTV account cookies.
 */
internal class AniyomiEphemeralCookieJar : CookieJar {
    private val cookies = mutableListOf<Cookie>()

    @Synchronized
    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        val now = System.currentTimeMillis()
        this.cookies.removeAll { it.expiresAt <= now }
        for (cookie in cookies) {
            this.cookies.removeAll {
                it.name == cookie.name && it.domain == cookie.domain && it.path == cookie.path
            }
            if (cookie.expiresAt <= now || !cookie.matches(url) || cookie.name.length + cookie.value.length > MAX_COOKIE_BYTES) {
                continue
            }
            this.cookies += cookie
            while (this.cookies.size > MAX_COOKIES || this.cookies.sumOf { it.name.length + it.value.length } > MAX_TOTAL_BYTES) {
                this.cookies.removeAt(0)
            }
        }
    }

    @Synchronized
    override fun loadForRequest(url: HttpUrl): List<Cookie> {
        val now = System.currentTimeMillis()
        cookies.removeAll { it.expiresAt <= now }
        return cookies.filter { it.matches(url) }.toList()
    }

    @Synchronized fun clear() = cookies.clear()

    private companion object {
        const val MAX_COOKIES = 64
        const val MAX_COOKIE_BYTES = 4096
        const val MAX_TOTAL_BYTES = 32 * 1024
    }
}

/**
 * Maps host-side failures to a small wire vocabulary. The provider target,
 * transport exception text and response details never cross the process.
 */
internal object AniyomiHttpBrokerFailurePolicy {
    const val UNSAFE_TARGET = "http_broker_unsafe_target"
    const val NETWORK = "http_broker_network"
    const val UNSUPPORTED = "http_broker_unsupported"
    const val INVALID_RESPONSE = "http_broker_invalid_response"

    private val unsafeReasons = setOf(
        "invalid_https_url",
        "invalid_https_host",
        "public_https_required",
        "https_port_not_allowed",
        "private_host_blocked",
        "private_network_blocked",
        "unexpected_dns_name",
        "invalid_redirect",
        "developer_access_revoked",
    )
    private val unsupportedReasons = setOf(
        "http_method_unsupported",
        "get_body_unsupported",
        "http_request_too_large",
        "http_headers_too_large",
        "http_header_not_permitted",
        "unsupported_http_field",
        "http_request_limit",
        "invalid_http_option",
        "http_redirect_unsupported",
        "http_redirect_limit",
        "http_response_too_large",
    )
    private val networkReasons = setOf(
        "request_cancelled_or_expired",
        "deadline_exceeded",
        "http_broker_unavailable",
    )

    fun code(error: Throwable): String {
        val reason = error.message
        return when {
            error is IOException || reason in networkReasons -> NETWORK
            reason in unsupportedReasons -> UNSUPPORTED
            reason in unsafeReasons || error is SecurityException -> UNSAFE_TARGET
            error is JSONException || error is IllegalArgumentException -> INVALID_RESPONSE
            // Unknown failures remain fail-closed and reveal no implementation detail.
            else -> UNSAFE_TARGET
        }
    }

    fun failureName(code: String): String = when (code) {
        UNSAFE_TARGET -> "policy"
        NETWORK -> "network"
        UNSUPPORTED -> "unsupported"
        INVALID_RESPONSE -> "invalid"
        else -> "policy"
    }

    fun responseSizeBucket(bytes: Long): String = when {
        bytes < 0 -> "none"
        bytes < 64L * 1024 -> "lt64k"
        bytes < 128L * 1024 -> "64to128k"
        bytes <= 256L * 1024 -> "128to256k"
        else -> "over256k"
    }

    fun statusClass(statusCode: Int): String =
        if (statusCode in 100..599) "${statusCode / 100}xx" else "none"
}
