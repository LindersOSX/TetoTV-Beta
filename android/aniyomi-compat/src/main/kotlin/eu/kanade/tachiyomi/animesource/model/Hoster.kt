// Aniyomi 39e9a749590b89b432f04b83725aaa12591371b2; Apache-2.0.
// Vendored by TetoTV. Runtime implementation retained.
// See third_party/aniyomi_compat/README.md for provenance and supported scope.
package eu.kanade.tachiyomi.animesource.model

import eu.kanade.tachiyomi.animesource.model.SerializableVideo.Companion.serialize
import eu.kanade.tachiyomi.animesource.model.SerializableVideo.Companion.toVideoList
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

open class Hoster(
    val hosterUrl: String = "",
    val hosterName: String = "",
    val videoList: List<Video>? = null,
    val internalData: String = "",
    val lazy: Boolean = false,
    val memo: JsonObject = JsonObject(emptyMap()),
) {
    @Transient
    @Volatile
    var status: State = State.IDLE

    enum class State {
        IDLE,
        LOADING,
        READY,
        ERROR,
    }

    /** Exact ext-lib 16 constructor family retained for existing APKs. */
    constructor(
        hosterUrl: String = "",
        hosterName: String = "",
        videoList: List<Video>? = null,
        internalData: String = "",
        lazy: Boolean = false,
    ) : this(hosterUrl, hosterName, videoList, internalData, lazy, JsonObject(emptyMap()))

    fun copy(
        hosterUrl: String = this.hosterUrl,
        hosterName: String = this.hosterName,
        videoList: List<Video>? = this.videoList,
        internalData: String = this.internalData,
        lazy: Boolean = this.lazy,
        memo: JsonObject = this.memo,
    ): Hoster {
        return Hoster(hosterUrl, hosterName, videoList, internalData, lazy, memo)
    }

    /** Exact pre-memo copy descriptor and its generated copy$default bridge. */
    @Deprecated("Binary compatibility for extension API 16", level = DeprecationLevel.HIDDEN)
    fun copy(
        hosterUrl: String = this.hosterUrl,
        hosterName: String = this.hosterName,
        videoList: List<Video>? = this.videoList,
        internalData: String = this.internalData,
        lazy: Boolean = this.lazy,
    ): Hoster = Hoster(hosterUrl, hosterName, videoList, internalData, lazy, memo)

    companion object {
        const val NO_HOSTER_LIST = "no_hoster_list"

        fun List<Video>.toHosterList(): List<Hoster> {
            return listOf(
                Hoster(
                    hosterUrl = "",
                    hosterName = NO_HOSTER_LIST,
                    videoList = this,
                ),
            )
        }
    }
}

@Serializable
data class SerializableHoster(
    val hosterUrl: String = "",
    val hosterName: String = "",
    val videoList: String? = null,
    val internalData: String = "",
    val lazy: Boolean = false,
    val memo: JsonObject = JsonObject(emptyMap()),
) {

    /** Exact pre-memo constructor retained for APKs compiled against extension API 16. */
    @Deprecated("Binary compatibility for extension API 16", level = DeprecationLevel.HIDDEN)
    constructor(
        hosterUrl: String,
        hosterName: String,
        videoList: String?,
        internalData: String,
        lazy: Boolean,
    ) : this(hosterUrl, hosterName, videoList, internalData, lazy, JsonObject(emptyMap()))

    /** Exact pre-memo Kotlin default-argument constructor descriptor. */
    @Suppress("INVISIBLE_MEMBER", "INVISIBLE_REFERENCE", "UNUSED_PARAMETER")
    @Deprecated("Binary compatibility for extension API 16", level = DeprecationLevel.HIDDEN)
    constructor(
        hosterUrl: String?,
        hosterName: String?,
        videoList: String?,
        internalData: String?,
        lazy: Boolean,
        mask: Int,
        marker: kotlin.jvm.internal.DefaultConstructorMarker?,
    ) : this(
        hosterUrl = if (mask and 0x01 != 0) "" else requireNotNull(hosterUrl),
        hosterName = if (mask and 0x02 != 0) "" else requireNotNull(hosterName),
        videoList = if (mask and 0x04 != 0) null else videoList,
        internalData = if (mask and 0x08 != 0) "" else requireNotNull(internalData),
        lazy = if (mask and 0x10 != 0) false else lazy,
        memo = JsonObject(emptyMap()),
    )

    /** Exact pre-memo kotlinx.serialization constructor descriptor. */
    @Suppress("DEPRECATION_ERROR", "INVISIBLE_MEMBER", "INVISIBLE_REFERENCE", "UNUSED_PARAMETER")
    @Deprecated("Binary compatibility for extension API 16", level = DeprecationLevel.HIDDEN)
    constructor(
        seen: Int,
        hosterUrl: String?,
        hosterName: String?,
        videoList: String?,
        internalData: String?,
        lazy: Boolean,
        marker: kotlinx.serialization.internal.SerializationConstructorMarker?,
    ) : this(
        hosterUrl = if (seen and 0x01 != 0) requireNotNull(hosterUrl) else "",
        hosterName = if (seen and 0x02 != 0) requireNotNull(hosterName) else "",
        videoList = if (seen and 0x04 != 0) videoList else null,
        internalData = if (seen and 0x08 != 0) requireNotNull(internalData) else "",
        lazy = if (seen and 0x10 != 0) lazy else false,
        memo = JsonObject(emptyMap()),
    )

    /** Exact pre-memo data-class copy descriptor and its generated copy$default bridge. */
    @Deprecated("Binary compatibility for extension API 16", level = DeprecationLevel.HIDDEN)
    fun copy(
        hosterUrl: String = this.hosterUrl,
        hosterName: String = this.hosterName,
        videoList: String? = this.videoList,
        internalData: String = this.internalData,
        lazy: Boolean = this.lazy,
    ): SerializableHoster = SerializableHoster(hosterUrl, hosterName, videoList, internalData, lazy, memo)

    companion object {
        fun List<Hoster>.serialize(): String =
            Json.encodeToString(
                this.map { host ->
                    SerializableHoster(
                        host.hosterUrl,
                        host.hosterName,
                        host.videoList?.serialize(),
                        host.internalData,
                        host.lazy,
                        host.memo,
                    )
                },
            )

        fun String.toHosterList(): List<Hoster> =
            Json.decodeFromString<List<SerializableHoster>>(this)
                .map { sHost ->
                    Hoster(
                        sHost.hosterUrl,
                        sHost.hosterName,
                        sHost.videoList?.toVideoList(),
                        sHost.internalData,
                        sHost.lazy,
                        sHost.memo,
                    )
                }
    }
}
