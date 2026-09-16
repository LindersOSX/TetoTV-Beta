package dev.animetv.anime_tv.aniyomi

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class AniyomiImageCapabilityStoreTest {
    private val extension = "aniyomi:manga:eu.example.fixture"
    private val otherExtension = "aniyomi:manga:eu.example.other"

    @Test fun `page grant hides URL and provider credentials and is extension bound`() {
        var tokenIndex = 0
        val store = AniyomiImageCapabilityStore(
            now = { 10L },
            tokenFactory = { token(++tokenIndex) },
        )
        val jar = AniyomiEphemeralCookieJar()
        val sanitized = AniyomiResultPolicy.sanitize(
            "pages",
            mapOf("pages" to listOf(mapOf(
                "index" to 91,
                "url" to "https://images.example.test/private/page.png?signature=secret",
                "headers" to mapOf(
                    "Authorization" to "Bearer provider-secret",
                    "Cookie" to "session=provider-secret",
                    "Referer" to "https://reader.example.test/chapter",
                ),
            ))),
            privateMangaImages = true,
        )
        val protected = store.protectResult("pages", sanitized, extension, 7L, jar)
        val row = (protected["pages"] as List<*>).single() as Map<*, *>

        assertEquals(setOf("index", "imageCapability"), row.keys)
        assertFalse(protected.toString().contains("images.example"))
        assertFalse(protected.toString().contains("provider-secret"))
        val capability = row["imageCapability"] as String
        val grant = store.resolve(extension, capability)
        assertEquals("https://images.example.test/private/page.png?signature=secret", grant.uri.toString())
        assertEquals("Bearer provider-secret", grant.headers["Authorization"])
        assertEquals("session=provider-secret", grant.headers["Cookie"])
        rejects { store.resolve(otherExtension, capability) }
    }

    @Test fun `cover grant consumes URL and headers and remains artwork scoped`() {
        val store = AniyomiImageCapabilityStore(now = { 20L }, tokenFactory = { token(1) })
        val sanitized = AniyomiResultPolicy.sanitize(
            "details",
            mapOf("item" to mapOf(
                "url" to "/series",
                "title" to "Fixture",
                "thumbnailUrl" to "https://covers.example.test/cover.jpg",
                "thumbnailHeaders" to mapOf("User-Agent" to "Provider fixture"),
            )),
            privateMangaImages = true,
        )
        val protected = store.protectResult(
            "details", sanitized, extension, 3L, AniyomiEphemeralCookieJar(),
        )
        val item = protected["item"] as Map<*, *>
        assertFalse(item.containsKey("thumbnailUrl"))
        assertFalse(item.containsKey("thumbnailHeaders"))
        val grant = store.resolve(extension, item["imageCapability"] as String)
        assertTrue(grant.artwork)
        assertEquals("Provider fixture", grant.headers["User-Agent"])
    }

    @Test fun `expiry count eviction and explicit clearing revoke grants`() {
        var clock = 100L
        var tokenIndex = 0
        val store = AniyomiImageCapabilityStore(
            maximumEntries = 2,
            ttlMs = 50,
            now = { clock },
            tokenFactory = { token(++tokenIndex) },
        )
        fun issue(owner: String): String {
            val protected = store.protectResult(
                "pages",
                mapOf("pages" to listOf(mapOf(
                    "index" to 0,
                    "url" to "https://images.example.test/$tokenIndex.png",
                    "headers" to emptyMap<String, String>(),
                ))),
                owner,
                1L,
                AniyomiEphemeralCookieJar(),
            )
            return (((protected["pages"] as List<*>).single() as Map<*, *>)["imageCapability"] as String)
        }

        val evicted = issue(extension)
        val cleared = issue(extension)
        val survivor = issue(otherExtension)
        assertEquals(2, store.sizeForTest())
        rejects { store.resolve(extension, evicted) }
        store.clear(extension)
        rejects { store.resolve(extension, cleared) }
        store.resolve(otherExtension, survivor)
        clock = 151L
        rejects { store.resolve(otherExtension, survivor) }
        assertEquals(0, store.sizeForTest())
    }

    @Test fun `public result mode still rejects credential image headers`() {
        rejects {
            AniyomiResultPolicy.sanitize("pages", mapOf("pages" to listOf(mapOf(
                "url" to "https://images.example.test/page.jpg",
                "headers" to mapOf("Authorization" to "Bearer private"),
            ))))
        }
    }

    private fun token(index: Int): String = "A".repeat(39) + index.toString().padStart(4, '0')

    private fun rejects(block: () -> Unit) {
        try {
            block()
            fail("Expected rejection")
        } catch (_: IllegalArgumentException) {
            // Expected.
        } catch (_: IllegalStateException) {
            // Expected.
        }
    }
}
