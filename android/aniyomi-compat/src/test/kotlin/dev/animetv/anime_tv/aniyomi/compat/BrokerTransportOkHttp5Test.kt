package dev.animetv.anime_tv.aniyomi.compat

import java.net.Proxy
import java.net.URI
import java.io.IOException
import java.util.Base64
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import eu.kanade.tachiyomi.network.NetworkHelper
import okhttp3.CookieJar
import okhttp3.Dns
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Test

class BrokerTransportOkHttp5Test {
    @Test fun boundedLargeResponsesReachProviderParsersWithoutTheOldOneMiBLimit() {
        for (size in listOf(256 * 1024 + 1, 1024 * 1024 + 1, BrokerTransport.MAX_RESPONSE_BYTES)) {
            val bytes = ByteArray(size) { (it % 251).toByte() }
            val transport = BrokerTransport { input ->
                response(input).put("bodyBase64", Base64.getEncoder().encodeToString(bytes))
                    .put("headers", JSONObject().put("Content-Length", size.toString()))
            }
            val client = OkHttpClient.Builder().addInterceptor(transport).build()
            client.newCall(request()).execute().use { response ->
                assertEquals(size.toLong(), response.body.contentLength())
                assertArrayEquals(bytes, response.body.bytes())
            }
            assertEquals("over256k", transport.lastResponseContext()?.responseSizeBucket)
        }
    }

    @Test fun responsesOneByteOverFourMiBStillFailClosed() {
        val transport = BrokerTransport { input ->
            response(input).put("bodyBase64", Base64.getEncoder().encodeToString(ByteArray(BrokerTransport.MAX_RESPONSE_BYTES + 1)))
        }
        val client = OkHttpClient.Builder().addInterceptor(transport).build()
        val failure = assertThrows(IOException::class.java) {
            client.newCall(request()).execute().close()
        }
        assertEquals(AniyomiBrokerInvalidResponse::class.java, failure.cause?.javaClass)
        assertNull(transport.lastResponseContext())
    }

    @Test fun networkHelperDefaultsFollowBothRedirectKindsAndExplicitCloneCanDisableThem() {
        val envelopes = ArrayList<JSONObject>()
        val transport = BrokerTransport { input ->
            envelopes.add(input)
            response(input)
        }
        val base = NetworkHelper(transport).client

        base.newCall(request()).execute().close()
        base.newBuilder().followRedirects(false).followSslRedirects(false).build()
            .newCall(request()).execute().close()

        assertEquals(true, envelopes[0].getBoolean("followRedirects"))
        assertEquals(true, envelopes[0].getBoolean("followSslRedirects"))
        assertEquals(false, envelopes[1].getBoolean("followRedirects"))
        assertEquals(false, envelopes[1].getBoolean("followSslRedirects"))
    }

    @Test fun providerRedirectSettingsAreSentToTrustedBrokerNotExposedAsWorkerAuthority() {
        val envelope = AtomicReference<JSONObject>()
        val transport = BrokerTransport { input ->
            envelope.set(input)
            response(input)
        }
        val client = OkHttpClient.Builder()
            .followRedirects(true)
            .followSslRedirects(false)
            .addInterceptor(transport)
            .addInterceptor { chain ->
                assertFalse(chain.followRedirects)
                assertFalse(chain.followSslRedirects)
                chain.proceed(chain.request())
            }
            .build()

        client.newCall(request()).execute().close()

        assertEquals(true, envelope.get().getBoolean("followRedirects"))
        assertEquals(false, envelope.get().getBoolean("followSslRedirects"))
    }

    @Test fun transportAuthorityMutationsFailBeforeBrokerInvocation() {
        val mutations = listOf<(Interceptor.Chain) -> Unit>(
            { it.withDns(Dns.SYSTEM) },
            { it.withProxy(Proxy.NO_PROXY) },
            { it.withSslSocketFactory(null, null) },
            { it.withCookieJar(CookieJar.NO_COOKIES) },
        )

        for (mutation in mutations) {
            val brokerCalls = AtomicInteger()
            val client = client(brokerCalls, Interceptor { chain ->
                mutation(chain)
                chain.proceed(chain.request())
            })

            val failure = assertThrows(IOException::class.java) {
                client.newCall(request()).execute().close()
            }
            assertEquals(AniyomiBrokerUnsupportedCapability::class.java, failure.cause?.javaClass)
            assertEquals(0, brokerCalls.get())
        }
    }

    @Test fun exposedOkHttp5TransportStateIsInertAndFailClosed() {
        val brokerCalls = AtomicInteger()
        val client = client(brokerCalls, Interceptor { chain ->
            assertFalse(chain.followSslRedirects)
            assertFalse(chain.followRedirects)
            assertFalse(chain.retryOnConnectionFailure)
            assertNotSame(Dns.SYSTEM, chain.dns)
            assertSame(CookieJar.NO_COOKIES, chain.cookieJar)
            assertNull(chain.cache)
            assertNull(chain.proxy)
            assertNull(chain.sslSocketFactoryOrNull)
            assertNull(chain.x509TrustManagerOrNull)
            assertEquals(listOf(Proxy.NO_PROXY), chain.proxySelector.select(URI("https://fixture.invalid")))
            assertEquals(0, chain.connectionPool.connectionCount())
            assertThrows(AniyomiBrokerUnsupportedCapability::class.java) {
                chain.dns.lookup("fixture.invalid")
            }
            assertThrows(AniyomiBrokerUnsupportedCapability::class.java) {
                chain.socketFactory.createSocket()
            }
            chain.proceed(chain.request())
        })

        client.newCall(request()).execute().use { response -> assertEquals(200, response.code) }
        assertEquals(1, brokerCalls.get())
    }

    @Test fun timeoutOverridesReachRemainingApplicationInterceptorAndBroker() {
        val brokerCalls = AtomicInteger()
        val observedCalls = AtomicInteger()
        val timeoutSetter = Interceptor { chain ->
            chain.withConnectTimeout(111, TimeUnit.MILLISECONDS)
                .withReadTimeout(222, TimeUnit.MILLISECONDS)
                .withWriteTimeout(333, TimeUnit.MILLISECONDS)
                .proceed(chain.request())
        }
        val observer = Interceptor { chain ->
            observedCalls.incrementAndGet()
            assertEquals(111, chain.connectTimeoutMillis())
            assertEquals(222, chain.readTimeoutMillis())
            assertEquals(333, chain.writeTimeoutMillis())
            chain.proceed(chain.request())
        }

        client(brokerCalls, timeoutSetter, observer).newCall(request()).execute().use { response ->
            assertEquals(200, response.code)
        }
        assertEquals(1, observedCalls.get())
        assertEquals(1, brokerCalls.get())
    }

    @Test fun singletonHeadersUseEffectiveValueAndTransportOwnedHostIsDropped() {
        val envelope = AtomicReference<JSONObject>()
        val transport = BrokerTransport { input ->
            envelope.set(input)
            response(input)
        }
        val request = Request.Builder()
            .url("https://fixture.invalid/test")
            .addHeader("Referer", "https://fixture.invalid/")
            .addHeader("Referer", "https://fixture.invalid/series")
            .addHeader("Accept", "text/html")
            .addHeader("Accept", "application/json")
            .addHeader("Host", "attacker.invalid")
            .build()

        OkHttpClient.Builder().addInterceptor(transport).build()
            .newCall(request).execute().close()

        val headers = envelope.get().getJSONObject("headers")
        assertEquals("https://fixture.invalid/series", headers.getString("Referer"))
        assertEquals("text/html, application/json", headers.getString("Accept"))
        assertFalse(headers.has("Host"))
    }

    @Test fun failedAttemptClearsPriorBrokerResponseContext() {
        val calls = AtomicInteger()
        val transport = BrokerTransport { input ->
            if (calls.incrementAndGet() == 1) response(input) else throw AniyomiBrokerNetworkFailure()
        }
        val client = OkHttpClient.Builder().addInterceptor(transport).build()

        client.newCall(request()).execute().close()
        assertEquals("2xx", transport.lastResponseContext()?.statusClass)
        assertThrows(AniyomiBrokerNetworkFailure::class.java) {
            client.newCall(request()).execute().close()
        }
        assertNull(transport.lastResponseContext())
    }

    private fun client(brokerCalls: AtomicInteger, vararg providerInterceptors: Interceptor): OkHttpClient {
        val transport = BrokerTransport { input ->
            brokerCalls.incrementAndGet()
            response(input)
        }
        return OkHttpClient.Builder().addInterceptor(transport).apply {
            providerInterceptors.forEach(::addInterceptor)
        }.build()
    }

    private fun request(): Request = Request.Builder().url("https://fixture.invalid/test").build()

    private fun response(input: JSONObject): JSONObject = JSONObject()
        .put("statusCode", 200)
        .put("url", input.getString("url"))
        .put("headers", JSONObject())
        .put("bodyBase64", Base64.getEncoder().encodeToString(ByteArray(0)))
}
