package dev.animetv.anime_tv.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AppDeepLinkPolicyTest {
    @Test
    fun `builds the scoped anime route`() {
        assertEquals(
            "tetotv://app/anime/123?episode=4",
            AppDeepLinkPolicy.animeUri(123, 4),
        )
    }

    @Test
    fun `allows only positive numeric anime routes`() {
        assertTrue(AppDeepLinkPolicy.isAllowed("tetotv://app/anime/123?episode=4"))
        assertTrue(AppDeepLinkPolicy.isAllowed("tetotv://app/anime/123"))
        assertFalse(AppDeepLinkPolicy.isAllowed("tetotv:///anime/123?episode=4"))
        assertFalse(AppDeepLinkPolicy.isAllowed("https://app/anime/123?episode=4"))
        assertFalse(AppDeepLinkPolicy.isAllowed("tetotv://evil/anime/123?episode=4"))
        assertFalse(AppDeepLinkPolicy.isAllowed("tetotv://app/anime/not-a-number"))
        assertFalse(AppDeepLinkPolicy.isAllowed("tetotv://app//anime//123"))
        assertFalse(AppDeepLinkPolicy.isAllowed("tetotv://app/anime/../123"))
        assertFalse(AppDeepLinkPolicy.isAllowed("tetotv://app/anime/123?episode=0"))
        assertFalse(AppDeepLinkPolicy.isAllowed("tetotv://app/anime/123?episode=4&admin=1"))
        assertFalse(AppDeepLinkPolicy.isAllowed("tetotv://app/settings/accounts"))
    }

    @Test
    fun `ignores Flutter route extras on the exported activity`() {
        val injectedRoute = "/resolve?anilistId=123&episode=1&autoplay=1"

        assertFalse(AppDeepLinkPolicy.isAllowed(injectedRoute))
        assertNull(AppDeepLinkPolicy.initialRouteForExportedActivity())
    }
}
