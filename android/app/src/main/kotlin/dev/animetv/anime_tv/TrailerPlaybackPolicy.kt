package dev.animetv.anime_tv

data class InAppTrailerRequest(
    val provider: String,
    val videoId: String,
    val title: String,
)

/** Strict capability boundary for the native in-app trailer surface. */
object TrailerPlaybackPolicy {
    private val youtubeId = Regex("^[A-Za-z0-9_-]{11}$")
    private val dailymotionId = Regex("^[A-Za-z0-9]{5,16}$")

    fun request(provider: String?, videoId: String?, title: String?): InAppTrailerRequest? {
        val normalizedProvider = provider?.trim()?.lowercase().orEmpty()
        val normalizedId = videoId?.trim().orEmpty()
        val valid = when (normalizedProvider) {
            "youtube" -> youtubeId.matches(normalizedId)
            "dailymotion" -> dailymotionId.matches(normalizedId)
            else -> false
        }
        if (!valid) return null
        val safeTitle = title
            ?.replace(Regex("[\\u0000-\\u001f\\u007f]"), " ")
            ?.replace(Regex("\\s+"), " ")
            ?.trim()
            ?.take(160)
            ?.takeIf(String::isNotBlank)
            ?: "Anime trailer"
        return InAppTrailerRequest(normalizedProvider, normalizedId, safeTitle)
    }

    fun embedUrl(request: InAppTrailerRequest): String = when (request.provider) {
        "youtube" ->
            "https://www.youtube-nocookie.com/embed/${request.videoId}" +
                "?autoplay=1&controls=1&rel=0&playsinline=1"
        "dailymotion" ->
            "https://www.dailymotion.com/embed/video/${request.videoId}" +
                "?autoplay=1&queue-enable=false&sharing-enable=false"
        else -> error("Unsupported trailer provider")
    }
}
