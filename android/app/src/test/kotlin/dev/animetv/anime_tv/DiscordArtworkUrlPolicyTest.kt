package dev.animetv.anime_tv

import org.junit.Assert.assertEquals
import org.junit.Test

class DiscordArtworkUrlPolicyTest {
    @Test
    fun `accepts bounded public https show artwork`() {
        val artwork = "https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/show.jpg"

        assertEquals(artwork, sanitizeDiscordArtworkUrl("  $artwork  "))
    }

    @Test
    fun `rejects unsafe or malformed artwork references`() {
        val rejected = listOf(
            null,
            "",
            "http://example.com/show.jpg",
            "https://user:secret@example.com/show.jpg",
            "https://example.com/show.jpg#private",
            "not a url",
            "https://example.com/${"a".repeat(301)}",
        )

        rejected.forEach { value ->
            assertEquals("", sanitizeDiscordArtworkUrl(value))
        }
    }
}
