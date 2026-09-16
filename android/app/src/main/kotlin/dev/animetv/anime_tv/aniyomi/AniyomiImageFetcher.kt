package dev.animetv.anime_tv.aniyomi

import android.os.SystemClock
import dev.animetv.anime_tv.MangaArtworkTranscoder
import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.net.Proxy
import java.net.URI
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import okhttp3.Call
import okhttp3.ConnectionPool
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.Dns
import okhttp3.OkHttpClient
import okhttp3.Request

/** Native image transport retaining the extension-scoped cookie jar. */
internal class AniyomiImageFetcher(
    private val deadline: Long,
    private val checkAccess: () -> Unit,
) {
    private val calls = ConcurrentHashMap.newKeySet<Call>()
    private val cancelled = AtomicBoolean(false)

    fun cancel() {
        cancelled.set(true)
        calls.toList().forEach(Call::cancel)
    }

    fun fetch(grant: AniyomiImageCapabilityStore.Grant): ByteArray {
        var uri = grant.uri
        val originalOrigin = origin(uri)
        var redirects = 0
        while (true) {
            checkAllowed()
            val addresses = resolvePublicAddresses(uri)
            val pinnedHost = uri.host
            val remaining = (deadline - SystemClock.elapsedRealtime()).coerceIn(1L, 15_000L)
            val client = OkHttpClient.Builder()
                .proxy(Proxy.NO_PROXY)
                // Compose the extension's explicit Cookie header with its
                // host-owned jar below; never let OkHttp overwrite one with
                // the other in BridgeInterceptor.
                .cookieJar(CookieJar.NO_COOKIES)
                .dns(object : Dns {
                    override fun lookup(hostname: String): List<InetAddress> {
                        require(hostname.equals(pinnedHost, ignoreCase = true)) { "unexpected_dns_name" }
                        return addresses
                    }
                })
                .followRedirects(false)
                .followSslRedirects(false)
                .retryOnConnectionFailure(false)
                .connectionPool(ConnectionPool(0, 1, TimeUnit.MILLISECONDS))
                .callTimeout(remaining, TimeUnit.MILLISECONDS)
                .connectTimeout(remaining.coerceAtMost(8_000L), TimeUnit.MILLISECONDS)
                .readTimeout(remaining.coerceAtMost(15_000L), TimeUnit.MILLISECONDS)
                .build()
            val request = Request.Builder().url(uri.toASCIIString())
            val requestHeaders = imageHeaders(
                grant.headers,
                sameOrigin = origin(uri) == originalOrigin,
            ).toMutableMap()
            val explicitCookieKey = requestHeaders.keys.firstOrNull { it.equals("cookie", true) }
            val explicitCookie = explicitCookieKey?.let(requestHeaders::remove)
            requestHeaders.forEach { (name, value) -> request.header(name, value) }
            val requestUrl = request.build().url
            val cookieValues = grant.cookieJar.loadForRequest(requestUrl)
                .joinToString("; ") { "${it.name}=${it.value}" }
            listOfNotNull(explicitCookie?.takeIf(String::isNotBlank), cookieValues.takeIf(String::isNotBlank))
                .joinToString("; ")
                .takeIf(String::isNotBlank)
                ?.let { request.header("Cookie", it) }
            val call = client.newCall(request.get().build())
            calls += call
            try {
                if (cancelled.get()) call.cancel()
                checkAllowed()
                call.execute().use { response ->
                    grant.cookieJar.saveFromResponse(
                        response.request.url,
                        Cookie.parseAll(response.request.url, response.headers),
                    )
                    if (response.code in REDIRECT_CODES) {
                        require(redirects < MAX_REDIRECTS) { "image_redirect_limit" }
                        val location = response.header("Location") ?: throw IllegalArgumentException("invalid_redirect")
                        uri = try {
                            AniyomiPolicy.publicHttps(uri.resolve(location).toASCIIString())
                        } catch (error: IllegalArgumentException) {
                            throw error
                        }
                        redirects++
                    } else {
                        require(response.code == 200) { "image_http_failure" }
                        val body = response.body
                        val declared = body.contentLength()
                        require(declared in -1L..MAX_IMAGE_BYTES.toLong() && declared != 0L) {
                            "image_response_too_large"
                        }
                        val output = ByteArrayOutputStream(
                            if (declared in 1..(512 * 1024)) declared.toInt() else 64 * 1024,
                        )
                        body.byteStream().use { stream ->
                            val buffer = ByteArray(8192)
                            while (true) {
                                checkAllowed()
                                val count = stream.read(buffer)
                                if (count < 0) break
                                require(output.size() + count <= MAX_IMAGE_BYTES) { "image_response_too_large" }
                                output.write(buffer, 0, count)
                            }
                        }
                        checkAllowed()
                        val encoded = output.toByteArray()
                        require(encoded.isNotEmpty()) { "image_empty" }
                        return try {
                            AniyomiImageSafety.inspect(encoded)
                            encoded
                        } catch (error: IllegalArgumentException) {
                            if (!grant.artwork || !AniyomiImageSafety.isIsoBmffImage(encoded)) throw error
                            MangaArtworkTranscoder.transcode(encoded)
                                ?: throw IllegalArgumentException("image_not_supported")
                        }
                    }
                }
            } finally {
                calls -= call
                client.connectionPool.evictAll()
                client.dispatcher.executorService.shutdown()
            }
        }
    }

    private fun resolvePublicAddresses(uri: URI): List<InetAddress> {
        checkAllowed()
        val addresses = InetAddress.getAllByName(uri.host).toList()
        require(addresses.isNotEmpty() && addresses.all(AniyomiPolicy::publicAddress)) {
            "private_network_blocked"
        }
        checkAllowed()
        return addresses
    }

    private fun checkAllowed() {
        checkAccess()
        check(!cancelled.get() && SystemClock.elapsedRealtime() < deadline) {
            "image_request_cancelled_or_expired"
        }
    }

    private fun imageHeaders(input: Map<String, String>, sameOrigin: Boolean): Map<String, String> {
        val headers = AniyomiImageHeaderPolicy.headers(input).toMutableMap()
        if (!sameOrigin) {
            headers.keys.removeAll { it.equals("authorization", true) || it.equals("cookie", true) }
        }
        val names = headers.keys.associateBy(String::lowercase)
        names["accept"]?.let { key ->
            if (headers.getValue(key).split(',').any { entry ->
                    entry.substringBefore(';').trim().lowercase() in UNSUPPORTED_ACCEPT_TYPES
                }) {
                headers[key] = SUPPORTED_ACCEPT
            }
        }
        if ("accept" !in names) headers["Accept"] = SUPPORTED_ACCEPT
        if ("user-agent" !in names) headers["User-Agent"] = "TetoTV/2 Android manga"
        return headers
    }

    private fun origin(uri: URI): String =
        "${uri.scheme.lowercase()}://${uri.host.lowercase()}:${if (uri.port == -1) 443 else uri.port}"

    internal companion object {
        const val MAX_IMAGE_BYTES = 20 * 1024 * 1024
        const val MAX_REDIRECTS = 5
        private const val SUPPORTED_ACCEPT = "image/jpeg,image/png,image/webp,image/gif;q=0.9"
        private val REDIRECT_CODES = setOf(301, 302, 303, 307, 308)
        private val UNSUPPORTED_ACCEPT_TYPES = setOf(
            "image/avif", "image/heif", "image/heic", "image/avif-sequence",
            "image/heif-sequence", "image/heic-sequence",
        )
    }
}
