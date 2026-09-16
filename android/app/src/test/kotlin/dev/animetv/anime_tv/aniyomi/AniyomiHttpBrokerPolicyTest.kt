package dev.animetv.anime_tv.aniyomi

import java.io.IOException
import java.lang.reflect.Modifier
import java.net.SocketTimeoutException
import java.net.URI
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import okhttp3.Cookie
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test

class AniyomiHttpBrokerPolicyTest {
    @Test fun `broker execute is not globally synchronized`() {
        val method = AniyomiHttpBroker::class.java.getDeclaredMethod(
            "execute",
            org.json.JSONObject::class.java,
        )
        assertFalse(Modifier.isSynchronized(method.modifiers))
    }

    @Test fun `standard cache directives are accepted case insensitively`() {
        val headers = AniyomiHttpBrokerInputPolicy.headers(
            mapOf(
                "Cache-Control" to "max-age=600",
                "user-agent" to "fixture",
                "X-Provider-Client" to "fixture-client",
            ),
        )

        assertEquals("max-age=600", headers["Cache-Control"])
        assertEquals("fixture", headers["user-agent"])
        assertEquals("fixture-client", headers["X-Provider-Client"])
    }

    @Test fun `credential headers and private referers remain blocked`() {
        val credential = assertThrows(IllegalArgumentException::class.java) {
            AniyomiHttpBrokerInputPolicy.headers(mapOf("Cookie" to "session=secret"))
        }
        assertEquals("http_header_not_permitted", credential.message)
        assertThrows(IllegalArgumentException::class.java) {
            AniyomiHttpBrokerInputPolicy.headers(mapOf("Authorization" to "Bearer secret"))
        }

        assertThrows(IllegalArgumentException::class.java) {
            AniyomiHttpBrokerInputPolicy.headers(mapOf("Referer" to "https://127.0.0.1/private"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            AniyomiHttpBrokerInputPolicy.headers(mapOf("Host" to "private.example"))
        }
    }

    @Test fun `search referer encodes literal title spaces without changing its public HTTPS authority`() {
        val headers = AniyomiHttpBrokerInputPolicy.headers(
            mapOf("Referer" to "https://kaa.lt/search?q=One Piece", "Origin" to "https://kaa.lt"),
        )
        assertEquals("https://kaa.lt/search?q=One%20Piece", headers["Referer"])
        assertEquals("https://kaa.lt", headers["Origin"])
        assertEquals(
            "https://kaa.lt/path%20name?q=already%20encoded",
            AniyomiHttpBrokerInputPolicy.headers(
                mapOf("Referer" to "https://kaa.lt/path name?q=already%20encoded"),
            )["Referer"],
        )
    }

    @Test fun `referer space compatibility cannot repair unsafe authorities or headers`() {
        for (value in listOf(
            "https://127.0.0.1/search?q=One Piece",
            "https://private.local/search?q=One Piece",
            "https://user:pass@kaa.lt/search?q=One Piece",
            "https://kaa .lt/search?q=One Piece",
            "https://kaa.lt\\@127.0.0.1/search?q=One Piece",
            "http://kaa.lt/search?q=One Piece",
            "https://kaa.lt:444/search?q=One Piece",
            "https://kaa.lt/search?q=One Piece#fragment",
            "https://kaa.lt/search?q=One\tPiece",
            "https://kaa.lt/search?q=One\r\nX-Injected: value",
            "https://kaa.lt/search?q=" + " ".repeat(800),
        )) {
            assertThrows(IllegalArgumentException::class.java) {
                AniyomiHttpBrokerInputPolicy.headers(mapOf("Referer" to value))
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            AniyomiHttpBrokerInputPolicy.headers(mapOf("Origin" to "https://kaa.lt/One Piece"))
        }
    }

    @Test fun `redirect method handling matches safe HTTP semantics`() {
        assertEquals("GET", AniyomiHttpBrokerInputPolicy.redirectedMethod(301, "POST"))
        assertEquals("GET", AniyomiHttpBrokerInputPolicy.redirectedMethod(302, "POST"))
        assertEquals("GET", AniyomiHttpBrokerInputPolicy.redirectedMethod(303, "POST"))
        assertEquals("POST", AniyomiHttpBrokerInputPolicy.redirectedMethod(307, "POST"))
        assertEquals("POST", AniyomiHttpBrokerInputPolicy.redirectedMethod(308, "POST"))
        assertEquals("GET", AniyomiHttpBrokerInputPolicy.redirectedMethod(302, "GET"))
    }

    @Test fun `redirect preferences are strict and legacy envelopes preserve prior behavior`() {
        val legacy = AniyomiHttpBrokerInputPolicy.redirectPreferences(emptyMap())
        assertEquals(true, legacy.followRedirects)
        assertEquals(false, legacy.followSslRedirects)

        val manual = AniyomiHttpBrokerInputPolicy.redirectPreferences(
            mapOf("followRedirects" to false, "followSslRedirects" to false),
        )
        assertEquals(false, manual.followRedirects)
        assertEquals(false, manual.followSslRedirects)

        val malformed = assertThrows(IllegalArgumentException::class.java) {
            AniyomiHttpBrokerInputPolicy.redirectPreferences(
                mapOf("followRedirects" to "false"),
            )
        }
        assertEquals("invalid_http_option", malformed.message)
    }

    @Test fun `manual redirects return a normalized public HTTPS location without consuming redirect budget`() {
        val decision = AniyomiHttpBrokerInputPolicy.redirectDecision(
            current = URI("https://video.example.com/season/episode"),
            location = "../login?next=episode",
            statusCode = 302,
            followedRedirects = AniyomiHttpBrokerInputPolicy.MAX_REDIRECTS,
            preferences = AniyomiRedirectPreferences(
                followRedirects = false,
                followSslRedirects = false,
            ),
        )

        assertFalse(decision.follow)
        assertEquals("https://video.example.com/login?next=episode", decision.location.toASCIIString())
    }

    @Test fun `automatic redirects remain bounded and preserve same scheme SSL semantics`() {
        val preferences = AniyomiRedirectPreferences(
            followRedirects = true,
            followSslRedirects = false,
        )
        val allowed = AniyomiHttpBrokerInputPolicy.redirectDecision(
            URI("https://video.example.com/watch"),
            "https://cdn.example.com/video",
            307,
            followedRedirects = 2,
            preferences = preferences,
        )
        assertEquals(true, allowed.follow)

        val limit = assertThrows(IllegalArgumentException::class.java) {
            AniyomiHttpBrokerInputPolicy.redirectDecision(
                URI("https://video.example.com/watch"),
                "https://cdn.example.com/video",
                307,
                followedRedirects = 3,
                preferences = preferences,
            )
        }
        assertEquals("http_redirect_limit", limit.message)
    }

    @Test fun `redirect locations cannot downgrade HTTPS or target private literal hosts`() {
        for (target in listOf("http://cdn.example.com/video", "https://127.0.0.1/private")) {
            assertThrows(IllegalArgumentException::class.java) {
                AniyomiHttpBrokerInputPolicy.redirectDecision(
                    URI("https://video.example.com/watch"),
                    target,
                    302,
                    followedRedirects = 0,
                    preferences = AniyomiRedirectPreferences(false, false),
                )
            }
        }
    }

    @Test fun `parallel broker calls atomically share one bounded request budget`() {
        val budget = AniyomiHttpRequestBudget(16)
        val ready = CountDownLatch(16)
        val start = CountDownLatch(1)
        val accepted = AtomicInteger()
        val pool = Executors.newFixedThreadPool(16)
        repeat(64) {
            pool.execute {
                ready.countDown()
                start.await()
                if (runCatching { budget.claim() }.isSuccess) accepted.incrementAndGet()
            }
        }
        assertEquals(true, ready.await(5, TimeUnit.SECONDS))
        start.countDown()
        pool.shutdown()
        assertEquals(true, pool.awaitTermination(5, TimeUnit.SECONDS))
        assertEquals(16, accepted.get())
        assertEquals(16, budget.usedCount)
        assertEquals(true, budget.limitHit)
    }

    @Test fun `HTTP diagnostics preserve failures through successful claims and snapshots`() {
        val budget = AniyomiHttpRequestBudget(AniyomiPolicy.MAX_HTTP_REQUESTS)
        val diagnostics = AniyomiHttpDiagnostics(budget)
        assertEquals("none", diagnostics.snapshot()["lastFailure"])
        assertEquals(false, diagnostics.snapshot()["requestLimitHit"])
        diagnostics.recordFailure(AniyomiHttpBrokerFailurePolicy.NETWORK)
        repeat(3) { budget.claim() } // Includes redirect claims, not only worker requests.
        val first = diagnostics.attachTo(mapOf("videos" to emptyList<Any>()))
        repeat(2) { budget.claim() }
        val next = diagnostics.snapshot()
        assertEquals(5, next["requestCount"])
        assertEquals(16, next["requestLimit"])
        assertEquals(1, next["failureCount"])
        assertEquals("network", next["lastFailure"])
        assertEquals(3, (first["httpDiagnostics"] as Map<*, *>)["requestCount"])
        assertEquals(0, AniyomiHttpDiagnostics(AniyomiHttpRequestBudget(16)).snapshot()["failureCount"])
    }

    @Test fun `HTTP diagnostics atomically retain all parallel failures within bounded counters`() {
        val budget = AniyomiHttpRequestBudget(16)
        val diagnostics = AniyomiHttpDiagnostics(budget)
        val start = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(16)
        repeat(48) {
            pool.execute {
                start.await()
                runCatching { budget.claim() }
                diagnostics.recordFailure(AniyomiHttpBrokerFailurePolicy.UNSUPPORTED)
            }
        }
        start.countDown()
        pool.shutdown()
        assertEquals(true, pool.awaitTermination(5, TimeUnit.SECONDS))
        assertEquals(mapOf(
            "requestCount" to 16, "requestLimit" to 16, "failureCount" to 48,
            "requestLimitHit" to true, "lastFailure" to "unsupported",
        ), diagnostics.snapshot())
        repeat(100) { diagnostics.recordFailure(AniyomiHttpBrokerFailurePolicy.NETWORK) }
        assertEquals(64, diagnostics.snapshot()["failureCount"])
        assertEquals("network", diagnostics.snapshot()["lastFailure"])
    }

    @Test fun `HTTP diagnostics are host authoritative and expose only a closed scalar vocabulary`() {
        val budget = AniyomiHttpRequestBudget(16)
        val diagnostics = AniyomiHttpDiagnostics(budget)
        diagnostics.recordFailure("https://secret.example/private?token=generated-test-secret")
        val forged = mapOf<String, Any?>(
            "videos" to emptyList<Any>(),
            "httpDiagnostics" to mapOf("requestCount" to 999, "lastFailure" to "generated-test-secret"),
        )
        val result = diagnostics.attachTo(forged)
        assertEquals(emptyList<Any>(), result["videos"])
        assertEquals(mapOf(
            "requestCount" to 0, "requestLimit" to 16, "failureCount" to 1,
            "requestLimitHit" to false, "lastFailure" to "policy",
        ), result["httpDiagnostics"])
        assertFalse(result.toString().contains("generated-test-secret"))
        assertFalse(result.toString().contains("https://"))
        assertEquals(999, (forged["httpDiagnostics"] as Map<*, *>)["requestCount"])
        assertEquals(setOf("policy", "network", "unsupported", "invalid"), listOf(
            AniyomiHttpBrokerFailurePolicy.UNSAFE_TARGET,
            AniyomiHttpBrokerFailurePolicy.NETWORK,
            AniyomiHttpBrokerFailurePolicy.UNSUPPORTED,
            AniyomiHttpBrokerFailurePolicy.INVALID_RESPONSE,
        ).map { code ->
            diagnostics.recordFailure(code)
            diagnostics.snapshot()["lastFailure"]
        }.toSet())
    }

    @Test fun `request limit flag changes only when a claim is actually rejected`() {
        val budget = AniyomiHttpRequestBudget(16)
        val diagnostics = AniyomiHttpDiagnostics(budget)
        repeat(16) { budget.claim() }
        assertEquals(false, diagnostics.snapshot()["requestLimitHit"])
        val error = assertThrows(IllegalArgumentException::class.java) { budget.claim() }
        diagnostics.recordFailure(AniyomiHttpBrokerFailurePolicy.code(error))
        assertEquals(true, diagnostics.snapshot()["requestLimitHit"])
        assertEquals(16, diagnostics.snapshot()["requestCount"])
        assertEquals("unsupported", diagnostics.snapshot()["lastFailure"])
        // Defensively clamp the output even if a nonproduction test budget is larger.
        val oversizedBudget = AniyomiHttpRequestBudget(17)
        repeat(17) { oversizedBudget.claim() }
        assertEquals(16, AniyomiHttpDiagnostics(oversizedBudget).snapshot()["requestCount"])
    }

    @Test fun `ephemeral cookies are scoped bounded and never cross domains`() {
        val jar = AniyomiEphemeralCookieJar()
        val origin = "https://video.example.com/watch".toHttpUrl()
        val cookie = Cookie.Builder().name("session").value("provider-value")
            .hostOnlyDomain("video.example.com").path("/").build()
        jar.saveFromResponse(origin, listOf(cookie))

        assertEquals(listOf(cookie), jar.loadForRequest("https://video.example.com/episode".toHttpUrl()))
        assertEquals(emptyList<Cookie>(), jar.loadForRequest("https://other.example.com/episode".toHttpUrl()))
        jar.saveFromResponse(origin, (0..64).map { index ->
            Cookie.Builder().name("fixture$index").value("value")
                .hostOnlyDomain("video.example.com").path("/").build()
        })
        assertEquals(64, jar.loadForRequest(origin).size)
        jar.clear()
        assertEquals(emptyList<Cookie>(), jar.loadForRequest(origin))
    }

    @Test fun `ephemeral cookie isolation remains safe under parallel hoster requests`() {
        val jar = AniyomiEphemeralCookieJar()
        val origin = "https://video.example.com/watch".toHttpUrl()
        val start = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(8)
        repeat(64) { index ->
            pool.execute {
                start.await()
                jar.saveFromResponse(
                    origin,
                    listOf(
                        Cookie.Builder().name("session$index").value("value")
                            .hostOnlyDomain("video.example.com").path("/").build(),
                    ),
                )
                jar.loadForRequest(origin)
            }
        }
        start.countDown()
        pool.shutdown()
        assertEquals(true, pool.awaitTermination(5, TimeUnit.SECONDS))
        assertEquals(64, jar.loadForRequest(origin).size)
        assertEquals(
            emptyList<Cookie>(),
            jar.loadForRequest("https://other.example.com/watch".toHttpUrl()),
        )
    }

    @Test fun `transport failures use fixed network category rather than unsafe target`() {
        for (failure in listOf(IOException("provider hostname"), SocketTimeoutException("provider timeout"))) {
            val code = AniyomiHttpBrokerFailurePolicy.code(failure)
            assertEquals(AniyomiHttpBrokerFailurePolicy.NETWORK, code)
            assertFalse(code.contains("provider"))
        }
    }

    @Test fun `policy capability and malformed input failures stay distinct and sanitized`() {
        assertEquals(
            AniyomiHttpBrokerFailurePolicy.UNSAFE_TARGET,
            AniyomiHttpBrokerFailurePolicy.code(IllegalArgumentException("private_network_blocked")),
        )
        assertEquals(
            AniyomiHttpBrokerFailurePolicy.UNSUPPORTED,
            AniyomiHttpBrokerFailurePolicy.code(IllegalArgumentException("http_header_not_permitted")),
        )
        assertEquals(
            AniyomiHttpBrokerFailurePolicy.UNSUPPORTED,
            AniyomiHttpBrokerFailurePolicy.code(IllegalArgumentException("unsupported_http_field")),
        )
        assertEquals(
            AniyomiHttpBrokerFailurePolicy.UNSUPPORTED,
            AniyomiHttpBrokerFailurePolicy.code(IllegalArgumentException("invalid_http_option")),
        )
        assertEquals(
            AniyomiHttpBrokerFailurePolicy.INVALID_RESPONSE,
            AniyomiHttpBrokerFailurePolicy.code(IllegalArgumentException("provider-secret")),
        )
        assertEquals(
            AniyomiHttpBrokerFailurePolicy.UNSAFE_TARGET,
            AniyomiHttpBrokerFailurePolicy.code(IllegalStateException("provider-secret")),
        )
        assertEquals("lt64k", AniyomiHttpBrokerFailurePolicy.responseSizeBucket(63 * 1024L))
        assertEquals("64to128k", AniyomiHttpBrokerFailurePolicy.responseSizeBucket(64 * 1024L))
        assertEquals("128to256k", AniyomiHttpBrokerFailurePolicy.responseSizeBucket(128 * 1024L))
        assertEquals("over256k", AniyomiHttpBrokerFailurePolicy.responseSizeBucket(256 * 1024L + 1))
        assertEquals("3xx", AniyomiHttpBrokerFailurePolicy.statusClass(302))
        assertEquals("none", AniyomiHttpBrokerFailurePolicy.statusClass(0))
        assertEquals(
            setOf("policy", "network", "unsupported", "invalid"),
            setOf(
                AniyomiHttpBrokerFailurePolicy.failureName(AniyomiHttpBrokerFailurePolicy.UNSAFE_TARGET),
                AniyomiHttpBrokerFailurePolicy.failureName(AniyomiHttpBrokerFailurePolicy.NETWORK),
                AniyomiHttpBrokerFailurePolicy.failureName(AniyomiHttpBrokerFailurePolicy.UNSUPPORTED),
                AniyomiHttpBrokerFailurePolicy.failureName(AniyomiHttpBrokerFailurePolicy.INVALID_RESPONSE),
            ),
        )
    }
}
