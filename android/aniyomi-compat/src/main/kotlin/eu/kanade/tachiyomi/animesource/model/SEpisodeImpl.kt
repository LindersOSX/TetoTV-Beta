// Aniyomi 39e9a749590b89b432f04b83725aaa12591371b2; Apache-2.0.
// Vendored by TetoTV. Runtime implementation retained.
// See third_party/aniyomi_compat/README.md for provenance and supported scope.
@file:Suppress("PropertyName")

package eu.kanade.tachiyomi.animesource.model

import kotlinx.serialization.json.JsonObject

class SEpisodeImpl : SEpisode {

    override lateinit var url: String

    override lateinit var name: String

    override var date_upload: Long = 0

    override var episode_number: Float = -1f

    override var fillermark: Boolean = false

    override var scanlator: String? = null

    override var summary: String? = null

    override var preview_url: String? = null

    override var memo: JsonObject = JsonObject(emptyMap())
}
