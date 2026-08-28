package dev.animetv.anime_tv.security

import java.net.URI

/** Strict allow-list for the only external route TetoTV publishes. */
internal object AppDeepLinkPolicy {
    const val SCHEME = "tetotv"
    const val HOST = "app"

    private val animePath = Regex("/anime/([1-9][0-9]*)")
    private val episodeQuery = Regex("episode=[1-9][0-9]*")

    fun animeUri(mediaId: Long, episode: Int): String {
        require(mediaId > 0L) { "A positive media ID is required." }
        require(episode > 0) { "A positive episode number is required." }
        return "$SCHEME://$HOST/anime/$mediaId?episode=$episode"
    }

    /**
     * Flutter's `route` intent extra is not an authenticated navigation
     * channel. MainActivity is exported for launchers, so any installed app
     * can supply this value. Returning null leaves Flutter to derive navigation
     * only from the separately validated Intent data URI.
     */
    fun initialRouteForExportedActivity(): String? = null

    fun isAllowed(value: String?): Boolean = runCatching {
        if (value.isNullOrBlank()) return@runCatching false
        val uri = URI(value)
        if (!uri.scheme.equals(SCHEME, ignoreCase = true)) return@runCatching false
        if (!uri.host.equals(HOST, ignoreCase = true)) return@runCatching false
        if (uri.port != -1 || uri.userInfo != null || uri.fragment != null) {
            return@runCatching false
        }
        val mediaId = animePath.matchEntire(uri.rawPath.orEmpty())
            ?.groupValues
            ?.get(1)
            ?.toLongOrNull()
        if (mediaId == null || mediaId <= 0L) return@runCatching false
        uri.rawQuery == null || episodeQuery.matches(uri.rawQuery)
    }.getOrDefault(false)
}
