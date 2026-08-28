package dev.animetv.anime_tv

import android.content.res.Configuration
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TelevisionDevicePolicyTest {
    @Test
    fun televisionUiModeIsTelevision() {
        assertTrue(
            TelevisionDevicePolicy.isTelevision(
                uiMode = Configuration.UI_MODE_TYPE_TELEVISION,
                hasLeanback = false,
                hasTelevisionFeature = false,
                hasAmazonFireTvFeature = false,
                hasHdmiCec = false,
                hasTouchscreen = false,
                manufacturer = "Google",
                brand = "Google",
                model = "ADT-3",
                device = "adt3",
                product = "adt3",
            ),
        )
    }

    @Test
    fun leanbackFeatureIsTelevisionEvenWithNormalUiMode() {
        assertTrue(
            TelevisionDevicePolicy.isTelevision(
                uiMode = Configuration.UI_MODE_TYPE_NORMAL,
                hasLeanback = true,
                hasTelevisionFeature = false,
                hasAmazonFireTvFeature = false,
                hasHdmiCec = false,
                hasTouchscreen = false,
                manufacturer = "Example",
                brand = "Example",
                model = "TV box",
                device = "tvbox",
                product = "tvbox",
            ),
        )
    }

    @Test
    fun olderFireTvAftModelIsTelevisionWithoutAndroidTvFlags() {
        assertTrue(
            TelevisionDevicePolicy.isTelevision(
                uiMode = Configuration.UI_MODE_TYPE_NORMAL,
                hasLeanback = false,
                hasTelevisionFeature = false,
                hasAmazonFireTvFeature = false,
                hasHdmiCec = false,
                hasTouchscreen = false,
                manufacturer = "Amazon",
                brand = "Amazon",
                model = "AFTMM",
                device = "aftmm",
                product = "aftmm",
            ),
        )
    }

    @Test
    fun fireTvFeatureWinsWhenFireOsHidesTheModelAndAndroidTvFlags() {
        assertTrue(
            TelevisionDevicePolicy.isTelevision(
                uiMode = Configuration.UI_MODE_TYPE_NORMAL,
                hasLeanback = false,
                hasTelevisionFeature = false,
                hasAmazonFireTvFeature = true,
                hasHdmiCec = false,
                hasTouchscreen = false,
                manufacturer = "Amazon",
                brand = "Amazon",
                model = "unknown",
                device = "unknown",
                product = "unknown",
            ),
        )
    }

    @Test
    fun amazonFireTvDeviceOrProductIdentifierSurvivesGenericModel() {
        assertTrue(
            TelevisionDevicePolicy.isTelevision(
                uiMode = Configuration.UI_MODE_TYPE_NORMAL,
                hasLeanback = false,
                hasTelevisionFeature = false,
                hasAmazonFireTvFeature = false,
                hasHdmiCec = false,
                hasTouchscreen = false,
                manufacturer = "Amazon",
                brand = "Amazon",
                model = "unknown",
                device = "AFTKA",
                product = "firetv_avalon",
            ),
        )
    }

    @Test
    fun remoteOnlyHdmiCecBoxIsTelevision() {
        assertTrue(
            TelevisionDevicePolicy.isTelevision(
                uiMode = Configuration.UI_MODE_TYPE_NORMAL,
                hasLeanback = false,
                hasTelevisionFeature = false,
                hasAmazonFireTvFeature = false,
                hasHdmiCec = true,
                hasTouchscreen = false,
                manufacturer = "Example",
                brand = "Example",
                model = "Living room box",
                device = "box",
                product = "box",
            ),
        )
    }

    @Test
    fun amazonTabletAndAndroidPhoneStayMobile() {
        assertFalse(
            TelevisionDevicePolicy.isTelevision(
                uiMode = Configuration.UI_MODE_TYPE_NORMAL,
                hasLeanback = false,
                hasTelevisionFeature = false,
                hasAmazonFireTvFeature = false,
                hasHdmiCec = false,
                hasTouchscreen = true,
                manufacturer = "Amazon",
                brand = "Amazon",
                model = "KFMUWI",
                device = "karnak",
                product = "karnak",
            ),
        )
        assertFalse(
            TelevisionDevicePolicy.isTelevision(
                uiMode = Configuration.UI_MODE_TYPE_NORMAL,
                hasLeanback = false,
                hasTelevisionFeature = false,
                hasAmazonFireTvFeature = false,
                hasHdmiCec = true,
                hasTouchscreen = true,
                manufacturer = "Google",
                brand = "Google",
                model = "Pixel 9",
                device = "tokay",
                product = "tokay",
            ),
        )
    }
}
