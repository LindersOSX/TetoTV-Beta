package dev.animetv.anime_tv.aniyomi

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.fail
import org.junit.Test

class AniyomiRequestPolicyTest {
    @Test
    fun `bounded Flutter timeout metadata is accepted but never reaches extension code`() {
        val request = AniyomiRequestPolicy.extensionEnvelope(
            mapOf(
                "extensionId" to "aniyomi:anime:eu.example.animeextension.en.fixture",
                "operation" to "search",
                "sourceId" to "8123456789012345678",
                "query" to "Fixture Show",
                "page" to 1,
                "timeoutMs" to 8_000,
                "requestId" to 73,
            ),
        )

        assertEquals("search", request["operation"])
        assertEquals("8123456789012345678", request["sourceId"])
        assertEquals("Fixture Show", request["query"])
        assertFalse(request.containsKey("timeoutMs"))
        assertFalse(request.containsKey("requestId"))
        assertEquals(73L, AniyomiRequestPolicy.clientRequestId(mapOf("requestId" to 73)))
    }

    @Test
    fun `timeout metadata remains integral bounded and fail closed`() {
        val base = mapOf(
            "extensionId" to "aniyomi:anime:eu.example.animeextension.en.fixture",
            "operation" to "search",
            "sourceId" to "1",
        )
        for (timeout in listOf(0, 10_001, -1, 1.5, Double.NaN)) {
            rejects { AniyomiRequestPolicy.extensionEnvelope(base + ("timeoutMs" to timeout)) }
        }
        for (requestId in listOf(0, -1, 1.5, Double.NaN, Int.MAX_VALUE.toLong() + 1L)) {
            rejects { AniyomiRequestPolicy.extensionEnvelope(base + ("requestId" to requestId)) }
        }
        rejects { AniyomiRequestPolicy.extensionEnvelope(base + ("unexpected" to true)) }
    }

    @Test
    fun `episode target and exact season target stay bounded to their operations`() {
        val base = mapOf(
            "extensionId" to "aniyomi:anime:eu.example.animeextension.en.fixture",
            "operation" to "episodes",
            "sourceId" to "1",
            "targetEpisode" to 4500,
            "targetSeason" to 2,
        )
        val request = AniyomiRequestPolicy.extensionEnvelope(base)
        assertEquals(4500, request["targetEpisode"])
        assertEquals(2, request["targetSeason"])

        for (episode in listOf(0, -1, 100_001, 1.5, Double.NaN)) {
            rejects { AniyomiRequestPolicy.extensionEnvelope(base + ("targetEpisode" to episode)) }
        }
        rejects { AniyomiRequestPolicy.extensionEnvelope(base - "targetEpisode") }
        rejects {
            AniyomiRequestPolicy.extensionEnvelope(
                base + mapOf("operation" to "search", "query" to "fixture"),
            )
        }

        val seasonRequest = AniyomiRequestPolicy.extensionEnvelope(
            mapOf(
                "extensionId" to "aniyomi:anime:eu.example.animeextension.en.fixture",
                "operation" to "seasons",
                "sourceId" to "1",
                "targetSeason" to 2,
            ),
        )
        assertEquals(2, seasonRequest["targetSeason"])
        rejects {
            AniyomiRequestPolicy.extensionEnvelope(seasonRequest - "targetSeason" + mapOf(
                "extensionId" to "aniyomi:anime:eu.example.animeextension.en.fixture",
                "sourceId" to "1",
            ))
        }
        rejects {
            AniyomiRequestPolicy.extensionEnvelope(
                mapOf(
                    "extensionId" to "aniyomi:anime:eu.example.animeextension.en.fixture",
                    "operation" to "seasons",
                    "sourceId" to "1",
                    "targetSeason" to 2,
                    "targetEpisode" to 1,
                ),
            )
        }
    }

    @Test
    fun `lazy hoster resolution is explicit bounded and videos only`() {
        val base = mapOf(
            "extensionId" to "aniyomi:anime:eu.example.animeextension.en.fixture",
            "operation" to "videos",
            "sourceId" to "1",
            "url" to "/episode/1",
            "resolveLazyHosters" to true,
            "lazyHosterLimit" to 8,
            "timeoutMs" to 750,
        )
        val request = AniyomiRequestPolicy.extensionEnvelope(base)
        assertEquals(true, request["resolveLazyHosters"])
        assertEquals(8, request["lazyHosterLimit"])
        assertEquals(750L, request["hosterLoadTimeoutMs"])
        assertEquals(600L, request["hosterWorkBudgetMs"])
        assertFalse(request.containsKey("timeoutMs"))

        for (limit in listOf(0, 9, -1, 1.5, Double.NaN)) {
            rejects { AniyomiRequestPolicy.extensionEnvelope(base + ("lazyHosterLimit" to limit)) }
        }
        rejects {
            AniyomiRequestPolicy.extensionEnvelope(base + ("resolveLazyHosters" to false))
        }
        rejects {
            AniyomiRequestPolicy.extensionEnvelope(
                base + mapOf("operation" to "search", "query" to "fixture"),
            )
        }
        rejects { AniyomiRequestPolicy.extensionEnvelope(base + ("hosterLoadTimeoutMs" to 1)) }
        rejects { AniyomiRequestPolicy.extensionEnvelope(base + ("hosterWorkBudgetMs" to 1)) }
        val full = AniyomiRequestPolicy.extensionEnvelope(base + ("timeoutMs" to 10_000))
        assertEquals(6_000L, full["hosterLoadTimeoutMs"])
        assertEquals(8_000L, full["hosterWorkBudgetMs"])
    }

    private fun rejects(block: () -> Unit) {
        try {
            block()
            fail("Expected request rejection")
        } catch (_: IllegalArgumentException) {
            // Expected fail-closed contract.
        } catch (_: IllegalStateException) {
            // Kotlin require/check may surface either fixed exception type.
        }
    }
}
