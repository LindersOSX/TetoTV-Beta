// Aniyomi 39e9a749590b89b432f04b83725aaa12591371b2; Apache-2.0.
// Vendored by TetoTV. Runtime implementation retained.
// See third_party/aniyomi_compat/README.md for provenance and supported scope.
@file:Suppress("PropertyName")

package eu.kanade.tachiyomi.animesource.model

import kotlinx.serialization.json.JsonObject
import java.io.Serializable

interface SEpisode : Serializable {

    var url: String

    var name: String

    var date_upload: Long

    var episode_number: Float

    var fillermark: Boolean

    var scanlator: String?

    var summary: String?

    var preview_url: String?

    /** API-17 opaque source metadata; ignored by the TetoTV JSON boundary. */
    var memo: JsonObject
        get() = JsonObject(emptyMap())
        set(@Suppress("UNUSED_PARAMETER") value) = Unit

    fun copyFrom(other: SEpisode) {
        name = other.name
        url = other.url
        date_upload = other.date_upload
        episode_number = other.episode_number
        fillermark = other.fillermark
        scanlator = other.scanlator
        summary = other.summary
        preview_url = other.preview_url
        memo = other.memo
    }

    companion object {
        fun create(): SEpisode {
            return SEpisodeImpl()
        }
    }
}
