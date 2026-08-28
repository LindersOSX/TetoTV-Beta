package dev.animetv.anime_tv

import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build

/**
 * Classifies TV devices without relying on a single inconsistent Android flag.
 *
 * Older Fire OS releases commonly report a normal UI mode and omit Leanback,
 * while their model identifier still uses Amazon's documented AFT family.
 * Treating those devices as phones launches mobile OAuth in a browser that is
 * difficult to operate with a remote, so keep the checks centralized here.
 */
internal object TelevisionDevicePolicy {
    private const val AMAZON_FIRE_TV_FEATURE = "amazon.hardware.fire_tv"
    private const val HDMI_CEC_FEATURE = "android.hardware.hdmi.cec"

    /**
     * Reads every available Android/Fire OS signal in one place so Flutter and
     * the Discord native bridge cannot disagree about the same device.
     */
    fun isTelevision(context: Context): Boolean {
        val packageManager = context.packageManager
        return isTelevision(
            uiMode = context.resources.configuration.uiMode,
            hasLeanback = packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK),
            hasTelevisionFeature =
                packageManager.hasSystemFeature(PackageManager.FEATURE_TELEVISION),
            hasAmazonFireTvFeature =
                packageManager.hasSystemFeature(AMAZON_FIRE_TV_FEATURE),
            hasHdmiCec = packageManager.hasSystemFeature(HDMI_CEC_FEATURE),
            hasTouchscreen =
                packageManager.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN),
            manufacturer = Build.MANUFACTURER.orEmpty(),
            brand = Build.BRAND.orEmpty(),
            model = Build.MODEL.orEmpty(),
            device = Build.DEVICE.orEmpty(),
            product = Build.PRODUCT.orEmpty(),
        )
    }

    fun isTelevision(
        uiMode: Int,
        hasLeanback: Boolean,
        hasTelevisionFeature: Boolean,
        hasAmazonFireTvFeature: Boolean,
        hasHdmiCec: Boolean,
        hasTouchscreen: Boolean,
        manufacturer: String,
        brand: String,
        model: String,
        device: String,
        product: String,
    ): Boolean {
        val uiModeType = uiMode and Configuration.UI_MODE_TYPE_MASK
        val amazonBuild =
            manufacturer.equals("Amazon", ignoreCase = true) ||
                brand.equals("Amazon", ignoreCase = true)
        val hasFireTvIdentifier = listOf(model, device, product).any { value ->
            value.startsWith("AFT", ignoreCase = true) ||
                value.contains("firetv", ignoreCase = true)
        }
        val isAmazonFireTv = hasAmazonFireTvFeature || (amazonBuild && hasFireTvIdentifier)

        // Some inexpensive certified Android TV boxes omit both UI-mode and
        // Leanback flags but expose HDMI-CEC and no physical touchscreen.
        val isRemoteOnlyHdmiDevice = hasHdmiCec && !hasTouchscreen
        return uiModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
            hasLeanback ||
            hasTelevisionFeature ||
            isAmazonFireTv ||
            isRemoteOnlyHdmiDevice
    }
}
