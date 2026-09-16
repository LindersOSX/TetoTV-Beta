// Aniyomi 39e9a749590b89b432f04b83725aaa12591371b2; Apache-2.0.
// Vendored by TetoTV. Runtime implementation retained.
// See third_party/aniyomi_compat/README.md for provenance and supported scope.
package eu.kanade.tachiyomi.animesource.model

import android.net.Uri
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import okhttp3.Headers

@Serializable
data class Track(val url: String, val lang: String)

@Serializable
enum class ChapterType {
    Opening,
    Ending,
    Recap,
    MixedOp,
    Other,
}

@Serializable
data class TimeStamp(
    val start: Double,
    val end: Double,
    val name: String,
    val type: ChapterType = ChapterType.Other,
)

data class Video(
    var videoUrl: String = "",
    val videoTitle: String = "",
    val resolution: Int? = null,
    val bitrate: Int? = null,
    val headers: Headers? = null,
    val preferred: Boolean = false,
    val subtitleTracks: List<Track> = emptyList(),
    val audioTracks: List<Track> = emptyList(),
    val timestamps: List<TimeStamp> = emptyList(),
    val mpvArgs: List<Pair<String, String>> = emptyList(),
    val ffmpegStreamArgs: List<Pair<String, String>> = emptyList(),
    val ffmpegVideoArgs: List<Pair<String, String>> = emptyList(),
    val internalData: String = "",
    val initialized: Boolean = false,
    val memo: JsonObject = JsonObject(emptyMap()),
) {

    // TODO(1.6): Remove after ext lib bump
    @Deprecated("Use videoTitle instead", ReplaceWith("videoTitle"))
    val quality: String
        get() = videoTitle

    // TODO(1.6): Remove after ext lib bump
    val url: String
        get() = videoPageUrl

    // TODO(1.6): Remove after ext lib bump
    private var videoPageUrl: String = ""

    // TODO(1.6): Remove after ext lib bump
    constructor(
        url: String,
        quality: String,
        videoUrl: String?,
        headers: Headers? = null,
        subtitleTracks: List<Track> = emptyList(),
        audioTracks: List<Track> = emptyList(),
    ) : this(
        videoTitle = quality,
        videoUrl = videoUrl ?: "null",
        headers = headers,
        subtitleTracks = subtitleTracks,
        audioTracks = audioTracks,
    ) {
        this.videoPageUrl = url
    }

    // TODO(1.6): Remove after ext lib bump
    @Suppress("UNUSED_PARAMETER")
    constructor(
        url: String,
        quality: String,
        videoUrl: String?,
        uri: Uri? = null,
        headers: Headers? = null,
    ) : this(url, quality, videoUrl, headers)

    /** Exact ext-lib 16 primary-constructor descriptor. */
    @Deprecated("Binary compatibility for extension API 16", level = DeprecationLevel.HIDDEN)
    constructor(
        videoUrl: String = "",
        videoTitle: String = "",
        resolution: Int? = null,
        bitrate: Int? = null,
        headers: Headers? = null,
        preferred: Boolean = false,
        subtitleTracks: List<Track> = emptyList(),
        audioTracks: List<Track> = emptyList(),
        timestamps: List<TimeStamp> = emptyList(),
        mpvArgs: List<Pair<String, String>> = emptyList(),
        ffmpegStreamArgs: List<Pair<String, String>> = emptyList(),
        ffmpegVideoArgs: List<Pair<String, String>> = emptyList(),
        internalData: String = "",
        initialized: Boolean = false,
    ) : this(
        videoUrl, videoTitle, resolution, bitrate, headers, preferred, subtitleTracks, audioTracks,
        timestamps, mpvArgs, ffmpegStreamArgs, ffmpegVideoArgs, internalData, initialized,
        JsonObject(emptyMap()),
    )

    /** Exact ext-lib 16 data-class copy descriptor. */
    @Deprecated("Binary compatibility for extension API 16", level = DeprecationLevel.HIDDEN)
    fun copy(
        videoUrl: String = this.videoUrl,
        videoTitle: String = this.videoTitle,
        resolution: Int? = this.resolution,
        bitrate: Int? = this.bitrate,
        headers: Headers? = this.headers,
        preferred: Boolean = this.preferred,
        subtitleTracks: List<Track> = this.subtitleTracks,
        audioTracks: List<Track> = this.audioTracks,
        timestamps: List<TimeStamp> = this.timestamps,
        mpvArgs: List<Pair<String, String>> = this.mpvArgs,
        ffmpegStreamArgs: List<Pair<String, String>> = this.ffmpegStreamArgs,
        ffmpegVideoArgs: List<Pair<String, String>> = this.ffmpegVideoArgs,
        internalData: String = this.internalData,
        initialized: Boolean = this.initialized,
    ): Video = Video(
        videoUrl, videoTitle, resolution, bitrate, headers, preferred, subtitleTracks, audioTracks,
        timestamps, mpvArgs, ffmpegStreamArgs, ffmpegVideoArgs, internalData, initialized,
        JsonObject(emptyMap()),
    )

    @Transient
    @Volatile
    var status: State = State.QUEUE
        set(value) {
            field = value
        }

    enum class State {
        QUEUE,
        LOAD_VIDEO,
        READY,
        ERROR,
    }

    companion object {
        const val MPV_ARGS_TAG = "ANIYOMI_MPV_ARGS"
    }
}

@Serializable
data class SerializableVideo(
    val videoUrl: String = "",
    val videoTitle: String = "",
    val resolution: Int? = null,
    val bitrate: Int? = null,
    val headers: List<Pair<String, String>>? = null,
    val preferred: Boolean = false,
    val subtitleTracks: List<Track> = emptyList(),
    val audioTracks: List<Track> = emptyList(),
    val timestamps: List<TimeStamp> = emptyList(),
    val mpvArgs: List<Pair<String, String>> = emptyList(),
    val ffmpegStreamArgs: List<Pair<String, String>> = emptyList(),
    val ffmpegVideoArgs: List<Pair<String, String>> = emptyList(),
    val internalData: String = "",
    val initialized: Boolean = false,
    val memo: JsonObject = JsonObject(emptyMap()),
) {

    /** Exact pre-memo constructor retained for APKs compiled against extension API 16. */
    @Deprecated("Binary compatibility for extension API 16", level = DeprecationLevel.HIDDEN)
    constructor(
        videoUrl: String,
        videoTitle: String,
        resolution: Int?,
        bitrate: Int?,
        headers: List<Pair<String, String>>?,
        preferred: Boolean,
        subtitleTracks: List<Track>,
        audioTracks: List<Track>,
        timestamps: List<TimeStamp>,
        mpvArgs: List<Pair<String, String>>,
        ffmpegStreamArgs: List<Pair<String, String>>,
        ffmpegVideoArgs: List<Pair<String, String>>,
        internalData: String,
        initialized: Boolean,
    ) : this(
        videoUrl, videoTitle, resolution, bitrate, headers, preferred, subtitleTracks, audioTracks,
        timestamps, mpvArgs, ffmpegStreamArgs, ffmpegVideoArgs, internalData, initialized,
        JsonObject(emptyMap()),
    )

    /** Exact pre-memo Kotlin default-argument constructor descriptor. */
    @Suppress("INVISIBLE_MEMBER", "INVISIBLE_REFERENCE", "UNUSED_PARAMETER")
    @Deprecated("Binary compatibility for extension API 16", level = DeprecationLevel.HIDDEN)
    constructor(
        videoUrl: String?,
        videoTitle: String?,
        resolution: Int?,
        bitrate: Int?,
        headers: List<Pair<String, String>>?,
        preferred: Boolean,
        subtitleTracks: List<Track>?,
        audioTracks: List<Track>?,
        timestamps: List<TimeStamp>?,
        mpvArgs: List<Pair<String, String>>?,
        ffmpegStreamArgs: List<Pair<String, String>>?,
        ffmpegVideoArgs: List<Pair<String, String>>?,
        internalData: String?,
        initialized: Boolean,
        mask: Int,
        marker: kotlin.jvm.internal.DefaultConstructorMarker?,
    ) : this(
        videoUrl = if (mask and 0x0001 != 0) "" else requireNotNull(videoUrl),
        videoTitle = if (mask and 0x0002 != 0) "" else requireNotNull(videoTitle),
        resolution = if (mask and 0x0004 != 0) null else resolution,
        bitrate = if (mask and 0x0008 != 0) null else bitrate,
        headers = if (mask and 0x0010 != 0) null else headers,
        preferred = if (mask and 0x0020 != 0) false else preferred,
        subtitleTracks = if (mask and 0x0040 != 0) emptyList() else requireNotNull(subtitleTracks),
        audioTracks = if (mask and 0x0080 != 0) emptyList() else requireNotNull(audioTracks),
        timestamps = if (mask and 0x0100 != 0) emptyList() else requireNotNull(timestamps),
        mpvArgs = if (mask and 0x0200 != 0) emptyList() else requireNotNull(mpvArgs),
        ffmpegStreamArgs = if (mask and 0x0400 != 0) emptyList() else requireNotNull(ffmpegStreamArgs),
        ffmpegVideoArgs = if (mask and 0x0800 != 0) emptyList() else requireNotNull(ffmpegVideoArgs),
        internalData = if (mask and 0x1000 != 0) "" else requireNotNull(internalData),
        initialized = if (mask and 0x2000 != 0) false else initialized,
        memo = JsonObject(emptyMap()),
    )

    /** Exact pre-memo kotlinx.serialization constructor descriptor. */
    @Suppress("DEPRECATION_ERROR", "INVISIBLE_MEMBER", "INVISIBLE_REFERENCE", "UNUSED_PARAMETER")
    @Deprecated("Binary compatibility for extension API 16", level = DeprecationLevel.HIDDEN)
    constructor(
        seen: Int,
        videoUrl: String?,
        videoTitle: String?,
        resolution: Int?,
        bitrate: Int?,
        headers: List<Pair<String, String>>?,
        preferred: Boolean,
        subtitleTracks: List<Track>?,
        audioTracks: List<Track>?,
        timestamps: List<TimeStamp>?,
        mpvArgs: List<Pair<String, String>>?,
        ffmpegStreamArgs: List<Pair<String, String>>?,
        ffmpegVideoArgs: List<Pair<String, String>>?,
        internalData: String?,
        initialized: Boolean,
        marker: kotlinx.serialization.internal.SerializationConstructorMarker?,
    ) : this(
        videoUrl = if (seen and 0x0001 != 0) requireNotNull(videoUrl) else "",
        videoTitle = if (seen and 0x0002 != 0) requireNotNull(videoTitle) else "",
        resolution = if (seen and 0x0004 != 0) resolution else null,
        bitrate = if (seen and 0x0008 != 0) bitrate else null,
        headers = if (seen and 0x0010 != 0) headers else null,
        preferred = if (seen and 0x0020 != 0) preferred else false,
        subtitleTracks = if (seen and 0x0040 != 0) requireNotNull(subtitleTracks) else emptyList(),
        audioTracks = if (seen and 0x0080 != 0) requireNotNull(audioTracks) else emptyList(),
        timestamps = if (seen and 0x0100 != 0) requireNotNull(timestamps) else emptyList(),
        mpvArgs = if (seen and 0x0200 != 0) requireNotNull(mpvArgs) else emptyList(),
        ffmpegStreamArgs = if (seen and 0x0400 != 0) requireNotNull(ffmpegStreamArgs) else emptyList(),
        ffmpegVideoArgs = if (seen and 0x0800 != 0) requireNotNull(ffmpegVideoArgs) else emptyList(),
        internalData = if (seen and 0x1000 != 0) requireNotNull(internalData) else "",
        initialized = if (seen and 0x2000 != 0) initialized else false,
        memo = JsonObject(emptyMap()),
    )

    /** Exact pre-memo data-class copy descriptor and its generated copy$default bridge. */
    @Deprecated("Binary compatibility for extension API 16", level = DeprecationLevel.HIDDEN)
    fun copy(
        videoUrl: String = this.videoUrl,
        videoTitle: String = this.videoTitle,
        resolution: Int? = this.resolution,
        bitrate: Int? = this.bitrate,
        headers: List<Pair<String, String>>? = this.headers,
        preferred: Boolean = this.preferred,
        subtitleTracks: List<Track> = this.subtitleTracks,
        audioTracks: List<Track> = this.audioTracks,
        timestamps: List<TimeStamp> = this.timestamps,
        mpvArgs: List<Pair<String, String>> = this.mpvArgs,
        ffmpegStreamArgs: List<Pair<String, String>> = this.ffmpegStreamArgs,
        ffmpegVideoArgs: List<Pair<String, String>> = this.ffmpegVideoArgs,
        internalData: String = this.internalData,
        initialized: Boolean = this.initialized,
    ): SerializableVideo = SerializableVideo(
        videoUrl, videoTitle, resolution, bitrate, headers, preferred, subtitleTracks, audioTracks,
        timestamps, mpvArgs, ffmpegStreamArgs, ffmpegVideoArgs, internalData, initialized, memo,
    )

    companion object {
        fun List<Video>.serialize(): String =
            Json.encodeToString(
                this.map { vid ->
                    SerializableVideo(
                        vid.videoUrl,
                        vid.videoTitle,
                        vid.resolution,
                        vid.bitrate,
                        vid.headers?.toList(),
                        vid.preferred,
                        vid.subtitleTracks,
                        vid.audioTracks,
                        vid.timestamps,
                        vid.mpvArgs,
                        vid.ffmpegStreamArgs,
                        vid.ffmpegVideoArgs,
                        vid.internalData,
                        vid.initialized,
                        vid.memo,
                    )
                },
            )

        fun String.toVideoList(): List<Video> =
            Json.decodeFromString<List<SerializableVideo>>(this)
                .map { sVid ->
                    Video(
                        sVid.videoUrl,
                        sVid.videoTitle,
                        sVid.resolution,
                        sVid.bitrate,
                        sVid.headers
                            ?.flatMap { it.toList() }
                            ?.let { Headers.headersOf(*it.toTypedArray()) },
                        sVid.preferred,
                        sVid.subtitleTracks,
                        sVid.audioTracks,
                        sVid.timestamps,
                        sVid.mpvArgs,
                        sVid.ffmpegStreamArgs,
                        sVid.ffmpegVideoArgs,
                        sVid.internalData,
                        sVid.initialized,
                        sVid.memo,
                    )
                }
    }
}
