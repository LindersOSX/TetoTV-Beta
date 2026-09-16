// Aniyomi 39e9a749590b89b432f04b83725aaa12591371b2; Apache-2.0.
// Vendored by TetoTV. Modified: Android-only runtime dependency/ABI adaptation.
// See third_party/aniyomi_compat/README.md for provenance and supported scope.
package eu.kanade.tachiyomi.animesource

import eu.kanade.tachiyomi.animesource.model.AnimeFilterList
import eu.kanade.tachiyomi.animesource.model.AnimesPage
import eu.kanade.tachiyomi.animesource.model.SAnime
import rx.Observable
import eu.kanade.tachiyomi.util.awaitSingle

interface AnimeCatalogueSource : AnimeSource {

    /**
     * An ISO 639-1 compliant language code (two letters in lower case).
     */
    override val lang: String

    /**
     * Whether the source has support for latest updates.
     */
    override val supportsLatest: Boolean

    /**
     * Get a page with a list of anime.
     *
     * @since extensions-lib 1.5
     * @param page the page number to retrieve.
     */
    @Suppress("DEPRECATION")
    override suspend fun getPopularAnime(page: Int): AnimesPage {
        return fetchPopularAnime(page).awaitSingle()
    }

    /**
     * Get a page with a list of anime.
     *
     * @since extensions-lib 1.5
     * @param page the page number to retrieve.
     * @param query the search query.
     * @param filters the list of filters to apply.
     */
    @Suppress("DEPRECATION")
    override suspend fun getSearchAnime(page: Int, query: String, filters: AnimeFilterList): AnimesPage {
        return fetchSearchAnime(page, query, filters).awaitSingle()
    }

    /**
     * Get a page with a list of latest anime updates.
     *
     * @since extensions-lib 1.5
     * @param page the page number to retrieve.
     */
    @Suppress("DEPRECATION")
    override suspend fun getLatestUpdates(page: Int): AnimesPage {
        return fetchLatestUpdates(page).awaitSingle()
    }

    /**
     * Returns the list of filters for the source.
     */
    override fun getFilterList(): AnimeFilterList

    /** Anikku/Komikku fork flags compiled into current Yuzono API-14 APKs. */
    val supportsRelatedAnimes: Boolean get() = false
    val disableRelatedAnimesBySearch: Boolean get() = false
    val disableRelatedAnimes: Boolean get() = false

    override suspend fun getRelatedAnimeList(
        anime: SAnime,
        exceptionHandler: (Throwable) -> Unit,
        pushResults: suspend (Pair<String, List<SAnime>>, Boolean) -> Unit,
    ): Unit = throw UnsupportedOperationException("Related anime is unsupported")

    suspend fun getRelatedAnimeListByExtension(
        anime: SAnime,
        pushResults: suspend (Pair<String, List<SAnime>>, Boolean) -> Unit,
    ): Unit = throw UnsupportedOperationException("Related anime is unsupported")

    suspend fun fetchRelatedAnimeList(anime: SAnime): List<SAnime> =
        throw UnsupportedOperationException("Related anime is unsupported")

    /** Komikku/Anikku helper ABI used by current Yuzono sources. */
    fun String.stripKeywordForRelatedAnimes(): List<String> =
        trim().split(Regex("\\s+")).filter(String::isNotBlank)

    suspend fun getRelatedAnimeListBySearch(
        anime: SAnime,
        exceptionHandler: (Throwable) -> Unit,
        pushResults: suspend (Pair<String, List<SAnime>>, Boolean) -> Unit,
    ): Unit = throw UnsupportedOperationException("Related anime search is unsupported")

    // Should be replaced as soon as Anime Extension reach 1.5
    @Deprecated(
        "Use the non-RxJava API instead",
        ReplaceWith("getPopularAnime"),
    )
    fun fetchPopularAnime(page: Int): Observable<AnimesPage>

    // Should be replaced as soon as Anime Extension reach 1.5
    @Deprecated(
        "Use the non-RxJava API instead",
        ReplaceWith("getSearchAnime"),
    )
    fun fetchSearchAnime(page: Int, query: String, filters: AnimeFilterList): Observable<AnimesPage>

    // Should be replaced as soon as Anime Extension reach 1.5
    @Deprecated(
        "Use the non-RxJava API instead",
        ReplaceWith("getLatestUpdates"),
    )
    fun fetchLatestUpdates(page: Int): Observable<AnimesPage>
}
