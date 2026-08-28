package dev.animetv.anime_tv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TrailerPlaybackPolicyTest {
    @Test
    fun `accepts a strict YouTube ID and sanitizes its title`() {
        val request = TrailerPlaybackPolicy.request(
            provider = " YouTube ",
            videoId = "abcDEF_12-3",
            title = "  Example\nTrailer  ",
        )

        requireNotNull(request)
        assertEquals("youtube", request.provider)
        assertEquals("abcDEF_12-3", request.videoId)
        assertEquals("Example Trailer", request.title)
        assertTrue(
            TrailerPlaybackPolicy.embedUrl(request)
                .startsWith("https://www.youtube-nocookie.com/embed/abcDEF_12-3?"),
        )
    }

    @Test
    fun `rejects unsupported providers and injected IDs`() {
        assertNull(TrailerPlaybackPolicy.request("vimeo", "abcDEF_12-3", "Trailer"))
        assertNull(
            TrailerPlaybackPolicy.request(
                "youtube",
                "abcDEF_12-3?autoplay=1",
                "Trailer",
            ),
        )
        assertNull(TrailerPlaybackPolicy.request("dailymotion", "../escape", "Trailer"))
    }
}
