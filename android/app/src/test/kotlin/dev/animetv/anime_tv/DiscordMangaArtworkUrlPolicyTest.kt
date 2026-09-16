package dev.animetv.anime_tv

import org.junit.Assert.assertEquals
import org.junit.Test

class DiscordMangaArtworkUrlPolicyTest {
    @Test
    fun `accepts ordinary public CDN domains without widening the anime policy`() {
        val covers = listOf(
            "https://covers.example.com/manga/front.jpg",
            "https://img42.cdn-public.net/books/front.webp",
            "https://covers.example.com/books/one%2Ftwo.jpg",
            "https://xn--bcher-kva.example.com/front.jpg",
        )
        covers.forEach { cover -> assertEquals(cover, sanitizeDiscordMangaArtworkUrl(cover)) }
        assertEquals(
            "https://covers.example.com/front.webp",
            sanitizeDiscordMangaArtworkUrl("  HTTPS://COVERS.EXAMPLE.COM:443/front.webp  "),
        )
        assertEquals(
            "https://covers.example.com/%E6%9B%B8.jpg",
            sanitizeDiscordMangaArtworkUrl("https://covers.example.com/書.jpg"),
        )
    }

    @Test
    fun `rejects account capabilities and all query or fragment forms`() {
        val rejected = listOf(
            "https://user:secret@covers.example.com/front.jpg",
            "https://user%3Asecret@covers.example.com/front.jpg",
            "https://covers.example.com/front.jpg?token=private",
            "https://covers.example.com/front.jpg?size=large",
            "https://covers.example.com/front.jpg?",
            "https://covers.example.com/front.jpg#private",
            "https://covers.example.com/front.jpg#",
            "https://covers.example.com:8443/front.jpg",
            "https://covers.example.com:/front.jpg",
            "https://covers.example.com:0443/front.jpg",
        )
        rejected.forEach { assertEquals(it, "", sanitizeDiscordMangaArtworkUrl(it)) }
    }

    @Test
    fun `rejects local reserved and numeric IP artwork targets without DNS lookups`() {
        val hosts = listOf(
            "localhost", "reader", "reader.localhost", "reader.local", "reader.lan",
            "reader.internal", "reader.home", "reader.home.arpa", "reader.localdomain",
            "reader.test", "reader.invalid", "reader.example", "reader.onion",
            "localhost.", "covers.example.com.", "127.0.0.1", "127.1", "0.0.0.0",
            "10.0.0.1", "172.16.0.1", "192.168.0.1", "169.254.169.254", "8.8.8.8",
            "2130706433", "0177.0.0.1", "0x7f000001", "0x7f.0.0.1",
            "0x7f.0x0.0x0.0x1", "[::1]", "[fe80::1]", "[::ffff:127.0.0.1]",
            "%31%32%37.0.0.1", "covers..example.com", "-covers.example.com",
            "covers_.example.com", "${"a".repeat(64)}.example.com", "cövérs.example.com",
        )
        hosts.forEach { host ->
            assertEquals(host, "", sanitizeDiscordMangaArtworkUrl("https://$host/front.jpg"))
        }
    }

    @Test
    fun `rejects raw encoded and nested controls and backslashes`() {
        val rejected = listOf(
            "https://covers.example.com/front.jpg\n",
            "https://covers.example.com/front\u0000.jpg",
            "https://covers.example.com/front\u200b.jpg",
            "https://covers.example.com/front\\private.jpg",
            "https://covers.example.com\\@localhost/front.jpg",
            "https://covers.example.com/front%0a.jpg",
            "https://covers.example.com/front%7F.jpg",
            "https://covers.example.com/front%C2%80.jpg",
            "https://covers.example.com/front%E2%80%8B.jpg",
            "https://covers.example.com/front%5cprivate.jpg",
            "https://covers.example.com/front%255Cprivate.jpg",
            "https://covers.example.com/front%250a.jpg",
            "https://covers.example.com/front%257f.jpg",
            "https://covers.example.com/front%20private.jpg",
            "https://covers.example.com/front private.jpg",
        )
        rejected.forEach { assertEquals(it, "", sanitizeDiscordMangaArtworkUrl(it)) }
    }

    @Test
    fun `missing invalid or oversized URLs fall back without truncating`() {
        val rejected = listOf(
            null, "", "   ", "not a cover", "//covers.example.com/front.jpg",
            "http://covers.example.com/front.jpg", "file:///private/front.jpg",
            "content://private/front.jpg", "data:image/png;base64,secret",
            "https://covers.example.com/%not-an-escape",
            "https://covers.example.com/${"a".repeat(301)}",
            "https://covers.example.com/${"書".repeat(100)}.jpg",
        )
        rejected.forEach { assertEquals("", sanitizeDiscordMangaArtworkUrl(it)) }
    }

    @Test
    fun `existing anime artwork behavior remains separate`() {
        val anime = "https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/show.jpg?size=large"
        assertEquals(anime, sanitizeDiscordArtworkUrl(anime))
        assertEquals("", sanitizeDiscordMangaArtworkUrl(anime))
    }
}
