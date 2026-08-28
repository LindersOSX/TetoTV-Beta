package dev.animetv.anime_tv

/** Validation shared by the private platform bridge and foreground service. */
object OfflineDownloadLeasePolicy {
    private val allowed = Regex("^[A-Za-z0-9._:-]{1,96}$")

    fun normalize(value: String?): String? =
        value?.trim()?.takeIf { allowed.matches(it) }
}
