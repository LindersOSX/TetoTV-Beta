package dev.animetv.anime_tv.aniyomi

import android.os.SystemClock
import android.util.Base64
import java.io.File
import java.net.InetAddress
import java.net.Proxy
import java.net.URI
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import okhttp3.Call
import okhttp3.ConnectionPool
import okhttp3.Dns
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONObject

/** A new, credential-free HTTP client; never shares TetoTV's cookies, headers or connections. */
internal class AniyomiHttpBroker(
    private val deadline: Long,
    private val checkAccess: () -> Unit,
    private val cacheDirectory: File,
    private val cookieJar: AniyomiEphemeralCookieJar = AniyomiEphemeralCookieJar(),
) {
    private val activeCalls = ConcurrentHashMap.newKeySet<Call>()
    private val activeBodies = ConcurrentHashMap.newKeySet<AniyomiHttpBodyFile>()
    private val cancelled = AtomicBoolean(false)
    private val requestBudget = AniyomiHttpRequestBudget(AniyomiPolicy.MAX_HTTP_REQUESTS)
    private val diagnostics = AniyomiHttpDiagnostics(requestBudget)
    private val diagnosticContext = ThreadLocal<BrokerDiagnosticContext>()

    fun cancel() {
        cancelled.set(true)
        activeCalls.toList().forEach(Call::cancel)
        activeBodies.toList().forEach { runCatching { it.close() } }
    }

    fun failure(error: Throwable): JSONObject {
        val context = diagnosticContext.get() ?: BrokerDiagnosticContext()
        diagnosticContext.remove()
        val code = AniyomiHttpBrokerFailurePolicy.code(error)
        diagnostics.recordFailure(code)
        return AniyomiWire.error(code)
            .put("broker_failure", AniyomiHttpBrokerFailurePolicy.failureName(code))
            .put("broker_reason", AniyomiHttpBrokerFailurePolicy.reason(error))
            .put("broker_redirect_count", context.redirectCount.coerceIn(0, 3))
            .put("broker_response_size_bucket", context.responseSizeBucket)
            .put("broker_status_class", context.statusClass)
    }

    fun withDiagnostics(result: Map<String, Any?>): Map<String, Any?> = diagnostics.attachTo(result)

    fun execute(input: JSONObject): AniyomiHttpReply {
        val context = BrokerDiagnosticContext()
        diagnosticContext.set(context)
        checkAllowed()
        require(input.keys().asSequence().all {
            it in setOf("url", "method", "headers", "bodyBase64", "followRedirects", "followSslRedirects")
        }) {
            "unsupported_http_field"
        }
        val redirectPreferences = AniyomiHttpBrokerInputPolicy.redirectPreferences(input)
        var method = input.optString("method", "GET")
        require(method == "GET" || method == "POST") { "http_method_unsupported" }
        val encodedBody = input.optString("bodyBase64", "")
        require(encodedBody.length <= 24 * 1024) { "http_request_too_large" }
        require(method == "POST" || encodedBody.isEmpty()) { "get_body_unsupported" }
        var body = if (method == "POST") Base64.decode(encodedBody, Base64.DEFAULT) else null
        val headers = input.optJSONObject("headers") ?: JSONObject()
        val safeHeaders = AniyomiHttpBrokerInputPolicy.headers(headers)
        var uri = AniyomiPolicy.publicHttps(input.getString("url"))
        while (true) {
            checkAllowed()
            requestBudget.claim()
            // Resolve once, validate ALL answers and force this exact set into the connection.
            val addresses = resolvePublicAddresses(uri)
            val pinnedHost = uri.host
            val remaining = (deadline - SystemClock.elapsedRealtime()).coerceIn(1L, 15_000L)
            val client = OkHttpClient.Builder()
                .proxy(Proxy.NO_PROXY).cookieJar(cookieJar).dns(object : Dns {
                    override fun lookup(hostname: String): List<InetAddress> {
                        require(hostname.equals(pinnedHost, true)) { "unexpected_dns_name" }
                        return addresses
                    }
                })
                .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
                .connectionPool(ConnectionPool(0, 1, TimeUnit.MILLISECONDS))
                .callTimeout(remaining, TimeUnit.MILLISECONDS)
                .connectTimeout(remaining.coerceAtMost(8_000L), TimeUnit.MILLISECONDS)
                .readTimeout(remaining.coerceAtMost(8_000L), TimeUnit.MILLISECONDS)
                .build()
            val request = Request.Builder().url(uri.toASCIIString())
            safeHeaders.forEach { (key, value) -> request.header(key, value) }
            val requestBody = body
            if (requestBody != null) {
                val contentType = safeHeaders.entries.firstOrNull { it.key.equals("content-type", true) }?.value
                request.post(requestBody.toRequestBody(contentType?.toMediaTypeOrNull()))
            }
            val call = client.newCall(request.build())
            activeCalls += call
            try {
                if (cancelled.get()) call.cancel()
                checkAllowed()
                call.execute().use { response ->
                    context.statusClass = AniyomiHttpBrokerFailurePolicy.statusClass(response.code)
                    if (response.code in setOf(301, 302, 303, 307, 308)) {
                        val location = response.header("Location") ?: throw IllegalArgumentException("invalid_redirect")
                        val decision = AniyomiHttpBrokerInputPolicy.redirectDecision(
                            current = uri,
                            location = location,
                            statusCode = response.code,
                            followedRedirects = context.redirectCount,
                            preferences = redirectPreferences,
                        )
                        if (!decision.follow) {
                            // Returning Location lets the extension apply its own
                            // no-follow behavior, but only after the destination is
                            // proven to be another public HTTPS host.
                            resolvePublicAddresses(decision.location)
                            val result = responseEnvelope(response, uri, context, decision.location)
                            diagnosticContext.remove()
                            return result
                        }
                        uri = decision.location
                        context.redirectCount++
                        // Match OkHttp/browser semantics: 301/302/303 turn POST
                        // into GET, while 307/308 safely retain method and body.
                        val redirectedMethod = AniyomiHttpBrokerInputPolicy.redirectedMethod(response.code, method)
                        if (redirectedMethod != method) {
                            method = redirectedMethod
                            body = null
                        }
                    } else {
                        val result = responseEnvelope(response, uri, context)
                        diagnosticContext.remove()
                        return result
                    }
                }
            } finally {
                activeCalls -= call
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

    private fun responseEnvelope(
        response: Response,
        responseUri: URI,
        context: BrokerDiagnosticContext,
        redirectLocation: URI? = null,
    ): AniyomiHttpReply {
        val bodyFile = AniyomiHttpBodyFile.create(cacheDirectory)
        activeBodies += bodyFile
        try {
            val size = response.body.byteStream().use { stream ->
                AniyomiHttpBodyPolicy.copy(
                    input = stream,
                    output = bodyFile.output,
                    declaredLength = response.body.contentLength(),
                    checkAllowed = ::checkAllowed,
                    observeSize = { context.responseSizeBucket = AniyomiHttpBrokerFailurePolicy.responseSizeBucket(it) },
                )
            }
            // Close the only writable handle before the read-only descriptor can
            // cross the process boundary. Cancellation also closes both handles.
            bodyFile.output.close()
            checkAllowed()
            val responseHeaders = JSONObject()
            for (key in listOf("Content-Type", "Content-Language", "Accept-Ranges")) {
                response.header(key)?.takeIf { it.length <= 2048 }?.let { responseHeaders.put(key, it) }
            }
            // OkHttp may transparently decode a response. Always describe the
            // exact buffered body sent to the worker, never an upstream encoded
            // Content-Length that can make provider parsers stop early.
            responseHeaders.put("Content-Length", size.toString())
            redirectLocation?.let { responseHeaders.put("Location", it.toASCIIString()) }
            val metadata = JSONObject().put("statusCode", response.code).put("url", responseUri.toASCIIString())
                .put("headers", responseHeaders)
                .put("bodyLength", size)
                // Internal, bounded context. The isolated runtime retains it only
                // if a later provider/parser step fails.
                .put("broker_redirect_count", context.redirectCount.coerceIn(0, 3))
            return AniyomiHttpReply(metadata, bodyFile) { activeBodies -= bodyFile }
        } catch (error: Throwable) {
            activeBodies -= bodyFile
            runCatching { bodyFile.close() }
            throw error
        }
    }

    private fun checkAllowed() {
        checkAccess()
        check(!cancelled.get() && SystemClock.elapsedRealtime() < deadline) {
            "request_cancelled_or_expired"
        }
    }

    private data class BrokerDiagnosticContext(
        var redirectCount: Int = 0,
        var responseSizeBucket: String = "none",
        var statusClass: String = "none",
    )
}
