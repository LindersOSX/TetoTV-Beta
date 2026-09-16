// Compatibility ABI adapted from Aniyomi; Apache-2.0.
package eu.kanade.tachiyomi

/** Privacy-stable host information exposed to extensions. */
@Suppress("UNUSED")
object AppInfo {
    fun getVersionCode(): Int = 0
    fun getVersionName(): String = "TetoTV isolated compatibility"
    fun getSupportedImageMimeTypes(): List<String> = listOf(
        "image/jpeg", "image/png", "image/gif", "image/webp", "image/avif",
    )
}
