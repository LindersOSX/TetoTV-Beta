// Aniyomi 39e9a749590b89b432f04b83725aaa12591371b2; Apache-2.0.
// Vendored by TetoTV. Runtime implementation retained.
// See third_party/aniyomi_compat/README.md for provenance and supported scope.
package eu.kanade.tachiyomi.animesource.model

/**
 * Define what type of content the anime should fetch.
 * The fetch type for a [SAnime] will not update after it's been initialized
 * to either Seasons or Episodes
 *
 * @since extensions-lib 16
 */
enum class FetchType {
    /**
     * [SAnime] will only call `getSeasonList`.
     */
    Seasons,

    /**
     * [SAnime] will only call `getEpisodeList`.
     */
    Episodes,
}
