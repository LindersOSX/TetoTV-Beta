package dev.animetv.anime_tv.aniyomi.compat

import okhttp3.Call
import okhttp3.Authenticator
import okhttp3.Cache
import okhttp3.CertificatePinner
import okhttp3.Connection
import okhttp3.ConnectionPool
import okhttp3.CookieJar
import okhttp3.Dns
import okhttp3.EventListener
import okhttp3.Headers
import okhttp3.HttpUrl
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okhttp3.internal.connection.RealCall
import okio.Buffer
import org.json.JSONObject
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.Socket
import java.net.URI
import java.util.Base64
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicInteger
import javax.net.SocketFactory
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.X509TrustManager

/** Narrow transport; the trusted process validates grants, hosts, DNS and redirects again. */
internal class BrokerTransport(private val broker: (JSONObject) -> JSONObject) : Interceptor {
    private val lastResponse = AtomicReference<AniyomiBrokerDiagnosticContext?>(null)

    /** Fixed context only; never retains a URL, header, cookie, body or exception. */
    fun lastResponseContext(): AniyomiBrokerDiagnosticContext? = lastResponse.get()

    override fun intercept(chain: Interceptor.Chain): Response = try {
        interceptChecked(chain)
    } catch (error: Exception) {
        // OkHttp's asynchronous dispatcher reports IOException to its callback,
        // but rethrows other failures on the dispatcher thread after doing so.
        // A normal, typed broker denial must not crash the isolated worker or
        // race its operation response. Preserve the fixed diagnostic as cause;
        // arbitrary extension exceptions retain their original behavior.
        if (error is AniyomiBrokerDiagnostic && error !is IOException) {
            throw IOException("http_broker_failure", error)
        }
        throw error
    }

    private fun interceptChecked(chain: Interceptor.Chain): Response {
        // This is pinned to the published Aniyomi OkHttp 5 ABI, not reflection.
        val call = chain.call() as? RealCall ?: unsupported("client_configuration")
        val ownIndexes = call.client.interceptors.mapIndexedNotNull { index, interceptor ->
            index.takeIf { interceptor === this }
        }
        if (call.forWebSocket) unsupported("client_websocket")
        if (ownIndexes.size != 1) unsupported("client_chain")
        if (call.client.proxy != null) unsupported("client_proxy")
        if (call.client.cache != null) unsupported("client_cache")
        // Extensions commonly append rate-limit, header or parser interceptors
        // after cloning NetworkHelper.client. Run that remaining application
        // chain inside the isolated process, but always terminate at broker().
        val brokerTerminal = { request: Request ->
            // Newer extension helpers use network interceptors for rate limits.
            // Execute their request/response callbacks in the same isolated,
            // socket-free chain, never in the trusted process's real client.
            ApplicationChain(
                call = call,
                interceptors = call.client.networkInterceptors,
                index = 0,
                currentRequest = request,
                connectTimeout = chain.connectTimeoutMillis(),
                readTimeout = chain.readTimeoutMillis(),
                writeTimeout = chain.writeTimeoutMillis(),
                networkAuthority = request.url,
                terminal = { checked ->
                    brokerRequest(checked, call.client.followRedirects, call.client.followSslRedirects)
                },
            ).proceed(request)
        }
        val remaining = call.client.interceptors.drop(ownIndexes.single() + 1)
        if (remaining.isNotEmpty()) {
            return ApplicationChain(
                call = call,
                interceptors = remaining,
                index = 0,
                currentRequest = chain.request(),
                connectTimeout = chain.connectTimeoutMillis(),
                readTimeout = chain.readTimeoutMillis(),
                writeTimeout = chain.writeTimeoutMillis(),
                terminal = brokerTerminal,
            ).proceed(chain.request())
        }
        return brokerTerminal(chain.request())
    }

    private fun brokerRequest(request: Request, followRedirects: Boolean, followSslRedirects: Boolean): Response {
        // Context belongs to one HTTP attempt. A parser failure after a later
        // request must never inherit the status/size of an earlier response.
        lastResponse.set(null)
        if (!request.url.isHttps) throw AniyomiBrokerPolicyDenied()
        if (request.method !in setOf("GET", "POST")) unsupported("request_method")
        val headers = JSONObject()
        for (name in request.headers.names()) {
            val lower = name.lowercase()
            if (lower in CREDENTIAL_HEADERS) {
                unsupported("credential_header")
            }
            // OkHttp derives these from the already-validated URL/body. Some
            // extensions redundantly set Host; ignoring it preserves ordinary
            // compatibility without ever letting an APK override routing.
            if (lower in TRANSPORT_MANAGED_HEADERS) continue
            val values = request.headers.values(name)
            if (values.isEmpty()) continue
            // Referer, Origin and other singleton fields use OkHttp's effective
            // (last) value. Comma-joining duplicate Referers creates a string
            // that is neither a valid URI nor what the provider requested.
            headers.put(
                name,
                if (lower in COMMA_JOINABLE_HEADERS) values.joinToString(", ") else values.last(),
            )
        }
        if (headers.toString().length > 8192) unsupported("request_headers")
        val envelope = JSONObject().put("url", request.url.toString())
            .put("method", request.method).put("headers", headers)
            // Preserve provider client semantics for the trusted broker. The
            // inert ApplicationChain values remain false so an interceptor
            // cannot mistake the worker for a network-capable chain.
            .put("followRedirects", followRedirects)
            .put("followSslRedirects", followSslRedirects)
        request.body?.let { body ->
            val size = body.contentLength()
            if (size < 0 || size > MAX_REQUEST_BYTES) unsupported("request_body")
            val buffer = Buffer()
            body.writeTo(buffer)
            if (buffer.size > MAX_REQUEST_BYTES) unsupported("request_body")
            envelope.put("bodyBase64", Base64.getEncoder().encodeToString(buffer.readByteArray()))
            body.contentType()?.let { headers.put("Content-Type", it.toString()) }
        }
        val result = broker(envelope)
        return try {
            val encoded = result.getString("bodyBase64")
            if (encoded.length > MAX_RESPONSE_BYTES * 4 / 3 + 8) throw AniyomiBrokerInvalidResponse()
            val bytes = Base64.getDecoder().decode(encoded)
            if (bytes.size > MAX_RESPONSE_BYTES) throw AniyomiBrokerInvalidResponse()
            val responseHeaders = Headers.Builder()
            result.optJSONObject("headers")?.let { values ->
                for (name in values.keys()) {
                    if (name.equals("Set-Cookie", true)) continue
                    responseHeaders.add(name, values.getString(name))
                }
            }
            val builtHeaders = responseHeaders.build()
            val code = result.getInt("statusCode")
            if (code !in 100..599) throw AniyomiBrokerInvalidResponse()
            val redirectCount = if (result.has("broker_redirect_count")) {
                result.getInt("broker_redirect_count")
            } else {
                // Backwards-compatible with old/fake broker replies.
                0
            }
            if (redirectCount !in 0..3) throw AniyomiBrokerInvalidResponse()
            val finalUrl = result.optString("url", request.url.toString())
            val responseRequest = request.newBuilder().url(finalUrl).build()
            if (!responseRequest.url.isHttps) throw AniyomiBrokerPolicyDenied()
            val response = Response.Builder().request(responseRequest).code(code)
                .protocol(Protocol.HTTP_1_1).message("Broker response").headers(builtHeaders)
                .body(bytes.toResponseBody(builtHeaders["Content-Type"]?.toMediaTypeOrNull())).build()
            lastResponse.set(
                AniyomiBrokerDiagnosticContext(
                    redirectCount = redirectCount,
                    responseSizeBucket = responseSizeBucket(bytes.size),
                    statusClass = "${code / 100}xx",
                ),
            )
            response
        } catch (error: AniyomiBrokerPolicyDenied) {
            throw error
        } catch (error: AniyomiBrokerInvalidResponse) {
            throw error
        } catch (_: Exception) {
            throw AniyomiBrokerInvalidResponse()
        }
    }

    private class ApplicationChain(
        private val call: Call,
        private val interceptors: List<Interceptor>,
        private val index: Int,
        private val currentRequest: Request,
        private val connectTimeout: Int,
        private val readTimeout: Int,
        private val writeTimeout: Int,
        private val networkAuthority: HttpUrl? = null,
        private val proceeds: AtomicInteger = AtomicInteger(),
        private val terminal: (Request) -> Response,
    ) : Interceptor.Chain {
        override fun request(): Request = currentRequest

        override fun proceed(request: Request): Response {
            if (networkAuthority != null) {
                if (proceeds.getAndIncrement() != 0 ||
                    request.url.scheme != networkAuthority.scheme ||
                    request.url.host != networkAuthority.host || request.url.port != networkAuthority.port
                ) unsupported("client_network_interceptor")
            }
            if (index >= interceptors.size) return terminal(request)
            val next = ApplicationChain(
                call,
                interceptors,
                index + 1,
                request,
                connectTimeout,
                readTimeout,
                writeTimeout,
                networkAuthority = networkAuthority,
                terminal = terminal,
            )
            val response = interceptors[index].intercept(next)
            if (networkAuthority != null && next.proceeds.get() != 1) {
                response.close()
                unsupported("client_network_interceptor")
            }
            return response
        }

        override fun connection(): Connection? = null
        override fun call(): Call = call
        override fun connectTimeoutMillis(): Int = connectTimeout
        override fun readTimeoutMillis(): Int = readTimeout
        override fun writeTimeoutMillis(): Int = writeTimeout
        override fun withConnectTimeout(timeout: Int, unit: TimeUnit): Interceptor.Chain = copy(
            connectTimeout = checkedTimeout(timeout, unit),
        )
        override fun withReadTimeout(timeout: Int, unit: TimeUnit): Interceptor.Chain = copy(
            readTimeout = checkedTimeout(timeout, unit),
        )
        override fun withWriteTimeout(timeout: Int, unit: TimeUnit): Interceptor.Chain = copy(
            writeTimeout = checkedTimeout(timeout, unit),
        )

        // OkHttp 5 exposes transport configuration on application chains. Do
        // not hand extension code the worker's real DNS/socket/TLS/proxy
        // capabilities: brokerRequest remains the sole terminal transport.
        override val followSslRedirects: Boolean = false
        override val followRedirects: Boolean = false
        override val dns: Dns = DENIED_DNS
        override val socketFactory: SocketFactory = DENIED_SOCKET_FACTORY
        override val retryOnConnectionFailure: Boolean = false
        override val authenticator: Authenticator = Authenticator.NONE
        override val cookieJar: CookieJar = CookieJar.NO_COOKIES
        override val cache: Cache? = null
        override val proxy: Proxy? = null
        override val proxySelector: ProxySelector = DIRECT_ONLY_PROXY_SELECTOR
        override val proxyAuthenticator: Authenticator = Authenticator.NONE
        override val sslSocketFactoryOrNull: SSLSocketFactory? = null
        override val x509TrustManagerOrNull: X509TrustManager? = null
        override val hostnameVerifier: HostnameVerifier = HostnameVerifier { _, _ -> false }
        override val certificatePinner: CertificatePinner = CertificatePinner.DEFAULT
        override val connectionPool: ConnectionPool = INERT_CONNECTION_POOL
        override val eventListener: EventListener = EventListener.NONE

        override fun withDns(dns: Dns): Interceptor.Chain = unsupportedTransportMutation()
        override fun withSocketFactory(socketFactory: SocketFactory): Interceptor.Chain = unsupportedTransportMutation()
        override fun withRetryOnConnectionFailure(retryOnConnectionFailure: Boolean): Interceptor.Chain =
            unsupportedTransportMutation()
        override fun withAuthenticator(authenticator: Authenticator): Interceptor.Chain = unsupportedTransportMutation()
        override fun withCookieJar(cookieJar: CookieJar): Interceptor.Chain = unsupportedTransportMutation()
        override fun withCache(cache: Cache?): Interceptor.Chain = unsupportedTransportMutation()
        override fun withProxy(proxy: Proxy?): Interceptor.Chain = unsupportedTransportMutation()
        override fun withProxySelector(proxySelector: ProxySelector): Interceptor.Chain = unsupportedTransportMutation()
        override fun withProxyAuthenticator(proxyAuthenticator: Authenticator): Interceptor.Chain =
            unsupportedTransportMutation()
        override fun withSslSocketFactory(
            sslSocketFactory: SSLSocketFactory?,
            x509TrustManager: X509TrustManager?,
        ): Interceptor.Chain = unsupportedTransportMutation()
        override fun withHostnameVerifier(hostnameVerifier: HostnameVerifier): Interceptor.Chain =
            unsupportedTransportMutation()
        override fun withCertificatePinner(certificatePinner: CertificatePinner): Interceptor.Chain =
            unsupportedTransportMutation()
        override fun withConnectionPool(connectionPool: ConnectionPool): Interceptor.Chain =
            unsupportedTransportMutation()

        private fun copy(
            connectTimeout: Int = this.connectTimeout,
            readTimeout: Int = this.readTimeout,
            writeTimeout: Int = this.writeTimeout,
        ) = ApplicationChain(
            call,
            interceptors,
            index,
            currentRequest,
            connectTimeout,
            readTimeout,
            writeTimeout,
            networkAuthority = networkAuthority,
            proceeds = proceeds,
            terminal = terminal,
        )

        private fun checkedTimeout(timeout: Int, unit: TimeUnit): Int {
            require(timeout >= 0)
            val millis = unit.toMillis(timeout.toLong())
            require(millis <= Int.MAX_VALUE)
            return millis.toInt()
        }

        private fun unsupportedTransportMutation(): Nothing = unsupported("transport_mutation")

        private companion object {
            val DENIED_DNS = Dns { unsupported("direct_network") }
            val INERT_CONNECTION_POOL = ConnectionPool(0, 1, TimeUnit.NANOSECONDS)
            val DIRECT_ONLY_PROXY_SELECTOR = object : ProxySelector() {
                override fun select(uri: URI?): List<Proxy> = listOf(Proxy.NO_PROXY)
                override fun connectFailed(uri: URI?, socketAddress: java.net.SocketAddress?, error: IOException?) = Unit
            }
            val DENIED_SOCKET_FACTORY = object : SocketFactory() {
                override fun createSocket(): Socket = denied()
                override fun createSocket(host: String?, port: Int): Socket = denied()
                override fun createSocket(host: String?, port: Int, localHost: InetAddress?, localPort: Int): Socket = denied()
                override fun createSocket(host: InetAddress?, port: Int): Socket = denied()
                override fun createSocket(address: InetAddress?, port: Int, localAddress: InetAddress?, localPort: Int): Socket = denied()
                private fun denied(): Nothing = unsupported("direct_network")
            }
        }
    }

    private fun responseSizeBucket(bytes: Int): String = when {
        bytes < 64 * 1024 -> "lt64k"
        bytes < 128 * 1024 -> "64to128k"
        bytes <= 256 * 1024 -> "128to256k"
        else -> "over256k"
    }

    companion object {
        private fun unsupported(reason: String): Nothing =
            throw AniyomiBrokerUnsupportedCapability(AniyomiBrokerDiagnosticContext(reason = reason))
        private const val MAX_REQUEST_BYTES = 1024 * 1024
        // In-process DTO only: the worker receives these bytes through a
        // bounded read-only FD, never as a large Binder JSON transaction.
        const val MAX_RESPONSE_BYTES = 4 * 1024 * 1024
        private val CREDENTIAL_HEADERS = setOf("cookie", "authorization", "proxy-authorization")
        private val TRANSPORT_MANAGED_HEADERS = setOf(
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
        )
        private val COMMA_JOINABLE_HEADERS = setOf(
            "accept",
            "accept-language",
            "cache-control",
            "pragma",
        )
    }
}
