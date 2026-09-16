// Aniyomi 39e9a749590b89b432f04b83725aaa12591371b2; Apache-2.0.
// Vendored by TetoTV. Runtime implementation retained.
// See third_party/aniyomi_compat/README.md for provenance and supported scope.
@file:Suppress("PropertyName")

package eu.kanade.tachiyomi.source.model

class SMangaImpl : SManga {

    override lateinit var url: String

    override lateinit var title: String

    override var artist: String? = null

    override var author: String? = null

    override var description: String? = null

    override var genre: String? = null

    override var status: Int = 0

    override var thumbnail_url: String? = null

    override var update_strategy: UpdateStrategy = UpdateStrategy.ALWAYS_UPDATE

    override var initialized: Boolean = false
}
