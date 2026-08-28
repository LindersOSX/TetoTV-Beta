package dev.animetv.anime_tv

import android.content.res.Configuration
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DiscordAuthFlowPolicyTest {
    @Test
    fun televisionModeUsesAndroidMobileFlow() {
        assertFalse(
            DiscordAuthFlowPolicy.shouldUseDeviceFlow(
                Configuration.UI_MODE_TYPE_TELEVISION,
                hasLeanback = false,
            ),
        )
    }

    @Test
    fun leanbackDeviceUsesAndroidMobileFlow() {
        assertFalse(
            DiscordAuthFlowPolicy.shouldUseDeviceFlow(
                Configuration.UI_MODE_TYPE_NORMAL,
                hasLeanback = true,
            ),
        )
    }

    @Test
    fun phoneKeepsMobileAuthorizationFlow() {
        assertFalse(
            DiscordAuthFlowPolicy.shouldUseDeviceFlow(
                Configuration.UI_MODE_TYPE_NORMAL,
                hasLeanback = false,
            ),
        )
    }

    @Test
    fun nativeMobileOauthIsBlockedOnTelevisions() {
        assertFalse(DiscordAuthFlowPolicy.allowsMobileOAuth(isTelevision = true))
        assertTrue(DiscordAuthFlowPolicy.allowsMobileOAuth(isTelevision = false))
    }
}
