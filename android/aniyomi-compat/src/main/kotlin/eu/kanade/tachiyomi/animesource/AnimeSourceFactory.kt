// Aniyomi 39e9a749590b89b432f04b83725aaa12591371b2; Apache-2.0.
// Vendored by TetoTV. Runtime implementation retained.
// See third_party/aniyomi_compat/README.md for provenance and supported scope.
package eu.kanade.tachiyomi.animesource

/**
 * A factory for creating sources at runtime.
 */
interface AnimeSourceFactory {
    /**
     * Create a new copy of the sources
     * @return The created sources
     */
    fun createSources(): List<AnimeSource>
}
