package dev.animetv.anime_tv

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ExternalPlaybackProxyPolicyTest {
    @Test
    fun `accepts only the opaque TetoTV loopback route`() {
        val session = "a".repeat(32)
        val resource = "B".repeat(32)
        assertTrue(
            ExternalPlaybackProxyPolicy.isTetoWebProxyUri(
                "http://127.0.0.1:43121/tetotv-web/v1/$session/$resource",
            ),
        )
        assertFalse(
            ExternalPlaybackProxyPolicy.isTetoWebProxyUri(
                "https://media.example/tetotv-web/v1/$session/$resource",
            ),
        )
        assertFalse(
            ExternalPlaybackProxyPolicy.isTetoWebProxyUri(
                "http://127.0.0.1:43121/tetotv-web/v1/$session/$resource?token=1",
            ),
        )
        assertFalse(
            ExternalPlaybackProxyPolicy.isTetoWebProxyUri(
                "http://127.0.0.1:43121/other/v1/$session/$resource",
            ),
        )
        assertFalse(
            ExternalPlaybackProxyPolicy.isTetoWebProxyUri(
                "http://127.0.0.1:43121/tetotv-web//v1/$session/$resource",
            ),
        )
        assertFalse(
            ExternalPlaybackProxyPolicy.isTetoWebProxyUri(
                "http://127.0.0.1:43121/tetotv-web/v1/$session/$resource/",
            ),
        )
    }
}
