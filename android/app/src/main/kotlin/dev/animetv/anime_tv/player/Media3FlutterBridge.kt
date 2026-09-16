package dev.animetv.anime_tv.player

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Typeface
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Base64
import android.util.TypedValue
import android.view.LayoutInflater
import android.view.PixelCopy
import android.view.SurfaceView
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.Metadata
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackGroup
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.Timeline
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.FilteringMediaSource
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.extractor.metadata.Chapter
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.CaptionStyleCompat
import androidx.media3.ui.PlayerView
import dev.animetv.anime_tv.R
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import okhttp3.OkHttpClient
import java.io.ByteArrayOutputStream
import java.util.concurrent.TimeUnit

/** A native surface/decoder only. Flutter owns navigation, controls and media identity. */
@androidx.annotation.OptIn(UnstableApi::class)
class Media3FlutterBridge(context: Context, engine: FlutterEngine) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val context = context.applicationContext
    private val handler = Handler(Looper.getMainLooper())
    private val methods = MethodChannel(engine.dartExecutor.binaryMessenger, "dev.tetotv/media3")
    private val events = EventChannel(engine.dartExecutor.binaryMessenger, "dev.tetotv/media3/events")
    private val sessions = linkedMapOf<Long, Media3Session>()
    private var nextId = 1L
    private var sink: EventChannel.EventSink? = null
    private var closed = false
    private var foreground = true
    private val pendingReleaseReplies = linkedSetOf<PendingMedia3ReleaseReply>()
    private val automaticReleaseReaps = linkedSetOf<Long>()

    init {
        // Media3's default exception logging can include a DataSpec URL. Our
        // event errors below are closed codes; do not log native stack traces.
        androidx.media3.common.util.Log.setLogLevel(androidx.media3.common.util.Log.LOG_LEVEL_OFF)
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
        engine.platformViewsController.registry.registerViewFactory(
            "dev.tetotv/media3/video",
            object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
                    val params = args as? Map<*, *>
                    val surfaceType = Media3BridgePolicy.surfaceType(params?.get("surfaceType"))
                    val id = params?.get("id") as? Number
                    val session = id?.toLong()?.let(sessions::get)
                        ?: throw IllegalArgumentException("Media3 player is unavailable")
                    return Media3VideoView(context, session, surfaceType)
                }
            },
        )
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        sessions.values.forEach(Media3Session::emitState)
    }

    override fun onCancel(arguments: Any?) { sink = null }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        // Default Flutter channel delivery and every ExoPlayer access share the
        // application main looper. Never dispatch player access to a worker.
        if (Looper.myLooper() != Looper.getMainLooper()) {
            handler.post { onMethodCall(call, result) }
            return
        }
        if (closed) {
            result.error("media3_closed", "Media3 is unavailable after activity teardown.", null)
            return
        }
        try {
            if (call.method == "create") {
                // A release can finish after its bounded Flutter reply. Sweep
                // proven-dead disposed sessions before applying ownership and
                // count limits so they cannot become permanent zombie slots.
                reapCompletedSessions()
                if (!Media3ProcessReleaseSafety.allReleased()) {
                    throw Media3ReleasePendingException()
                }
                check(sessions.size < Media3BridgePolicy.MAX_PLAYERS)
                val id = nextId++
                sessions[id] = Media3Session(context, id, handler, foreground) { event ->
                    if (!closed) runCatching { sink?.success(event) }
                }
                result.success(mapOf("id" to id))
                return
            }
            val id = Media3BridgePolicy.integer(call.argument<Any?>("id"), 1, Long.MAX_VALUE)
                ?: throw IllegalArgumentException("invalid_id")
            val session = sessions[id]
            if (session == null && call.method == "dispose") {
                result.success(null)
                return
            }
            requireNotNull(session)
            when (call.method) {
                "open" -> session.open(call.arguments as? Map<*, *> ?: emptyMap<Any, Any>())
                "play" -> session.play()
                "pause" -> session.pause()
                "seek" -> session.seek(requireNotNull(Media3BridgePolicy.integer(call.argument<Any?>("positionMs"))))
                "stop" -> session.stop()
                "dispose" -> {
                    val callStartedMs = SystemClock.elapsedRealtime()
                    session.dispose()
                    val reply = PendingMedia3ReleaseReply(result)
                    pendingReleaseReplies += reply
                    awaitReleaseCompletion(
                        id = id,
                        session = session,
                        reply = reply,
                        callStartedMs = callStartedMs,
                        pollStartedMs = SystemClock.elapsedRealtime(),
                    )
                    return
                }
                "setRate" -> session.setRate(requireNotNull(Media3BridgePolicy.number(call.argument<Any?>("rate"), 0.25, 4.0)).toFloat())
                "setVolume" -> session.setVolume(requireNotNull(Media3BridgePolicy.number(call.argument<Any?>("volume"), 0.0, 1.0)).toFloat())
                "setAudioTrack" -> session.setTrack(call.argument<String>("trackId").orEmpty(), C.TRACK_TYPE_AUDIO)
                "setSubtitleTrack" -> session.setTrack(call.argument<String>("trackId").orEmpty(), C.TRACK_TYPE_TEXT)
                "setDecoderMode" -> session.setDecoderMode(call.argument<String>("mode").orEmpty())
                "setOptions" -> {
                    val options = call.argument<Map<*, *>>("options") ?: emptyMap<Any, Any>()
                    val unsupported = Media3BridgePolicy.unsupportedOptions(options)
                    if (unsupported.isNotEmpty()) {
                        result.error("unsupported_options", "These controls are unavailable in Media3.", mapOf("options" to unsupported))
                        return
                    }
                    session.setOptions(options)
                }
                "addSubtitleTrack" -> {
                    result.success(session.addSubtitle(call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()))
                    return
                }
                "screenshot" -> {
                    session.screenshot(call.argument<String>("format") ?: "image/jpeg") { bytes ->
                        runCatching { result.success(bytes) }
                    }
                    return
                }
                "readProperty" -> { result.success(session.readProperty(call.argument<String>("property").orEmpty())); return }
                "ready" -> { result.success(true); return }
                else -> { result.notImplemented(); return }
            }
            result.success(null)
        } catch (_: Media3ReleasePendingException) {
            result.error("media3_release_pending", "Media3 is still releasing the playback session.", null)
        } catch (_: UnsupportedOperationException) {
            result.error("media3_unsupported", "The selected format or decoder is unavailable in Media3 on this device.", null)
        } catch (_: IllegalArgumentException) {
            result.error("media3_invalid_argument", "Invalid Media3 playback argument.", null)
        } catch (_: Exception) {
            result.error("media3_command_failed", "Media3 could not complete the playback command.", null)
        }
    }

    fun setForeground(value: Boolean) {
        if (closed) return
        foreground = value
        sessions.values.forEach { it.setForeground(value) }
    }

    private fun awaitReleaseCompletion(
        id: Long,
        session: Media3Session,
        reply: PendingMedia3ReleaseReply,
        callStartedMs: Long,
        pollStartedMs: Long,
    ) {
        val now = SystemClock.elapsedRealtime()
        val pollElapsedMs = (now - pollStartedMs).coerceAtLeast(0L)
        val totalElapsedMs = (now - callStartedMs)
            .coerceIn(0L, Media3BridgePolicy.RELEASE_TOTAL_TIMEOUT_MS)
        when (
            media3ReleasePollAction(
                playbackThreadAlive = session.playbackThreadAlive,
                elapsedMs = pollElapsedMs,
            )
        ) {
            Media3ReleasePollAction.COMPLETE -> {
                if (sessions[id] === session) sessions.remove(id)
                automaticReleaseReaps.remove(id)
                pendingReleaseReplies.remove(reply)
                reply.success(
                    mapOf(
                        "stage" to "release_waiting",
                        "status" to if (session.releaseRequiredWait) {
                            "completed_after_wait"
                        } else {
                            "completed"
                        },
                        "reasonCode" to "media3_release_complete",
                        "waitElapsedMs" to totalElapsedMs,
                        "timeoutMs" to Media3BridgePolicy.RELEASE_TOTAL_TIMEOUT_MS,
                        "playbackThreadAlive" to false,
                    ),
                )
            }
            Media3ReleasePollAction.WAIT -> handler.postDelayed(
                {
                    awaitReleaseCompletion(
                        id = id,
                        session = session,
                        reply = reply,
                        callStartedMs = callStartedMs,
                        pollStartedMs = pollStartedMs,
                    )
                },
                Media3BridgePolicy.RELEASE_POLL_INTERVAL_MS,
            )
            Media3ReleasePollAction.TIMED_OUT -> {
                pendingReleaseReplies.remove(reply)
                reply.error(
                    "media3_release_pending",
                    "Media3 is still releasing the playback session.",
                    mapOf(
                        "stage" to "release_waiting",
                        "status" to "failed",
                        "reasonCode" to "media3_release_pending",
                        "waitElapsedMs" to totalElapsedMs,
                        "timeoutMs" to Media3BridgePolicy.RELEASE_TOTAL_TIMEOUT_MS,
                        "playbackThreadAlive" to true,
                    ),
                )
                scheduleAutomaticReleaseReap(id, session)
            }
        }
    }

    private fun scheduleAutomaticReleaseReap(id: Long, session: Media3Session) {
        if (!automaticReleaseReaps.add(id)) return
        pollAutomaticReleaseReap(
            id = id,
            session = session,
            startedMs = SystemClock.elapsedRealtime(),
        )
    }

    private fun pollAutomaticReleaseReap(
        id: Long,
        session: Media3Session,
        startedMs: Long,
    ) {
        if (closed || sessions[id] !== session) {
            automaticReleaseReaps.remove(id)
            return
        }
        val elapsedMs = (SystemClock.elapsedRealtime() - startedMs).coerceAtLeast(0L)
        when (
            media3ReleaseReapAction(
                playbackThreadAlive = session.playbackThreadAlive,
                elapsedMs = elapsedMs,
            )
        ) {
            Media3ReleaseReapAction.REAP -> {
                if (sessions[id] === session) sessions.remove(id)
                automaticReleaseReaps.remove(id)
            }
            Media3ReleaseReapAction.WAIT -> handler.postDelayed(
                {
                    pollAutomaticReleaseReap(
                        id = id,
                        session = session,
                        startedMs = startedMs,
                    )
                },
                Media3BridgePolicy.RELEASE_AUTOMATIC_REAP_INTERVAL_MS,
            )
            Media3ReleaseReapAction.STOP -> {
                // The process-wide owned-thread registry still blocks a new
                // decoder. The next create performs a final proven-dead sweep,
                // even if Dart never retries dispose for this session ID.
                automaticReleaseReaps.remove(id)
            }
        }
    }

    private fun reapCompletedSessions() {
        val completed = sessions.entries
            .filter { (_, session) -> session.releaseCanBeReaped }
            .map { (id, _) -> id }
        completed.forEach { id ->
            sessions.remove(id)
            automaticReleaseReaps.remove(id)
        }
    }

    fun close() {
        if (closed) return
        closed = true
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
        val interruptedReleases = pendingReleaseReplies.toList()
        pendingReleaseReplies.clear()
        interruptedReleases.forEach {
            it.error(
                "media3_closed",
                "Media3 closed while waiting for player cleanup.",
                null,
            )
        }
        sessions.values.forEach { runCatching(it::dispose) }
        sessions.clear()
        automaticReleaseReaps.clear()
        handler.removeCallbacksAndMessages(null)
    }
}

/** Completes a pending Flutter dispose call exactly once during teardown. */
private class PendingMedia3ReleaseReply(private val result: MethodChannel.Result) {
    private var completed = false

    fun success(details: Map<String, Any?>) {
        if (completed) return
        completed = true
        runCatching { result.success(details) }
    }

    fun error(code: String, message: String, details: Map<String, Any?>?) {
        if (completed) return
        completed = true
        runCatching { result.error(code, message, details) }
    }
}

@androidx.annotation.OptIn(UnstableApi::class)
private class Media3VideoView(context: Context, private val session: Media3Session, surfaceType: String) : PlatformView {
    // PlayerView chooses its rendering surface at inflation time, before player attachment.
    private val layout = if (surfaceType == "surface") R.layout.media3_flutter_surface_video else R.layout.media3_flutter_video
    private val video = (LayoutInflater.from(context).inflate(layout, null) as PlayerView).apply {
        useController = false
        controllerAutoShow = false
        isFocusable = false
        isFocusableInTouchMode = false
        isClickable = false
        descendantFocusability = ViewGroup.FOCUS_BLOCK_DESCENDANTS
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        setShowBuffering(PlayerView.SHOW_BUFFERING_NEVER)
        setKeepContentOnPlayerReset(false)
    }
    init { session.attach(video) }
    override fun getView(): View = video
    override fun dispose() { session.detach(video) }
}

@androidx.annotation.OptIn(UnstableApi::class)
private class Media3Session(
    private val context: Context,
    private val id: Long,
    private val handler: Handler,
    private var foreground: Boolean,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    private data class Sidecar(val id: String, val uri: String, val title: String?, val language: String?, val mimeType: String)
    private data class AudioSidecar(val uri: String, val title: String?, val language: String?, val mimeType: String)
    private data class OpenRequest(val uri: String, val headers: Map<String, String>, val openId: Long, val subtitles: List<Sidecar>, val audioTracks: List<AudioSidecar>, val mimeType: String?, val endMs: Long?)
    private var request: OpenRequest? = null
    private var player: ExoPlayer? = null
    private var releaseThread: Thread? = null
    private var releaseRequiredWaitState = false
    private var httpClient: OkHttpClient? = null
    private var activeMediaSourceFactory: DefaultMediaSourceFactory? = null
    private var view: PlayerView? = null
    private val callbacks = Media3CallbackEpoch()
    private var eventGeneration = 0L
    private var openId = 0L
    private var disposed = false
    // Separate from the bridge handler, whose callbacks are cleared on teardown:
    // a completed PixelCopy must still recycle its destination bitmap.
    private val screenshotHandler = Handler(Looper.getMainLooper())
    private var pendingScreenshot: Media3ScreenshotResult? = null
    private var desiredPlaying = false
    private var rate = 1f
    private var volume = 1f
    private var decoderMode = "hardware"
    private var audioSelection = "auto"
    private var subtitleSelection = "auto"
    private var nextSidecar = 0
    private val sidecarAliases = mutableMapOf<String, String>()
    // TrackGroup equality includes its source ID and complete immutable Format
    // contents, not selection/support flags or callback arrival order.
    private val groupIds = Media3TrackIdentityRegistry<TrackGroup>()
    private val trackOverrides = linkedMapOf<String, TrackSelectionOverride>()
    private val options = mutableMapOf<String, Any?>()
    private var decoderName: String? = null
    private var firstFrameAfterMs: Long? = null
    private var openStartedMs = 0L
    private var terminalError: String? = null
    private var externalAudioFallbackApplied = false
    private val chapters = sortedMapOf<Long, String?>()
    private var chapterPeriodUid: Any? = null
    private val tick = object : Runnable {
        override fun run() {
            if (disposed || player == null || !foreground) return
            emitState()
            val active = player?.playbackState
            if (active == Player.STATE_READY || active == Player.STATE_BUFFERING) handler.postDelayed(this, 250)
        }
    }

    fun open(raw: Map<*, *>) {
        val uri = raw["uri"] as? String ?: throw IllegalArgumentException("invalid_uri")
        require(Media3BridgePolicy.supportedUri(uri))
        val nextOpenId = requireNotNull(Media3BridgePolicy.integer(raw["openId"], 1, Int.MAX_VALUE.toLong()))
        val startMs = if (raw["startMs"] == null) 0L else requireNotNull(Media3BridgePolicy.integer(raw["startMs"]))
        val endMs = Media3BridgePolicy.endPositionMs(raw["endMs"], startMs)
        val headers = Media3BridgePolicy.headers(raw["headers"])
        val subtitles = raw["subtitles"] as? List<*> ?: emptyList<Any>()
        require(subtitles.size <= Media3BridgePolicy.MAX_SIDECARS)
        val parsed = subtitles.mapIndexed { index, item ->
            val fields = item as? Map<*, *> ?: throw IllegalArgumentException("invalid_subtitle")
            parseSidecar(fields, "sidecar:${index + 1}")
        }
        val audioTracks = raw["audioTracks"] as? List<*> ?: emptyList<Any>()
        require(audioTracks.size <= Media3BridgePolicy.MAX_AUDIO_SIDECARS)
        val parsedAudio = audioTracks.map { item ->
            val fields = item as? Map<*, *> ?: throw IllegalArgumentException("invalid_audio_sidecar")
            parseAudioSidecar(fields)
        }
        val mimeType = (raw["mimeType"] as? String)?.lowercase()?.substringBefore(';')?.trim()
        require(mimeType == null || mimeType in setOf(MimeTypes.APPLICATION_M3U8, "application/x-mpegurl", MimeTypes.APPLICATION_MPD, "video/mp4", "video/webm", "video/x-matroska", "video/mp2t", "application/octet-stream"))
        val next = OpenRequest(uri, headers, nextOpenId, parsed, parsedAudio, if (mimeType == "application/x-mpegurl") MimeTypes.APPLICATION_M3U8 else mimeType, endMs)
        releasePlayer()
        request = next
        openId = nextOpenId
        nextSidecar = parsed.size
        sidecarAliases.clear()
        groupIds.clear() // Genuine new open only; decoder restart preserves IDs.
        audioSelection = "auto"
        subtitleSelection = "auto"
        externalAudioFallbackApplied = false
        desiredPlaying = raw["play"] as? Boolean ?: true
        createPlayer(next, startMs)
    }

    private fun createPlayer(open: OpenRequest, startMs: Long) {
        check(!disposed)
        val ticket = callbacks.begin(open.openId)
        eventGeneration = ticket.generation
        val eventOpenId = open.openId
        terminalError = null
        decoderName = null
        firstFrameAfterMs = null
        openStartedMs = SystemClock.elapsedRealtime()
        trackOverrides.clear()
        chapters.clear()
        chapterPeriodUid = null
        val http = OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(20, TimeUnit.SECONDS)
            .followRedirects(true)
            .followSslRedirects(false)
            .addNetworkInterceptor(Media3OriginHeaderInterceptor(open.uri, open.headers.keys))
            .build()
        httpClient = http
        val dataSource = DefaultDataSource.Factory(context,
            OkHttpDataSource.Factory(http).setDefaultRequestProperties(open.headers))
        val mediaSourceFactory = DefaultMediaSourceFactory(dataSource)
        activeMediaSourceFactory = mediaSourceFactory
        val software = decoderMode == "software"
        val selector = MediaCodecSelector { mime, secure, tunneling ->
            val decoders = MediaCodecSelector.DEFAULT.getDecoderInfos(mime, secure, tunneling)
            if (software && mime.startsWith("video/")) decoders.filter { it.softwareOnly } else decoders
        }
        val native = ExoPlayer.Builder(context)
            // Release completion below relies on the default per-player owned
            // PlaybackLooperProvider. Never introduce a shared/external
            // playback looper without replacing that ownership barrier.
            .setLooper(Looper.getMainLooper())
            .setRenderersFactory(DefaultRenderersFactory(context).setEnableDecoderFallback(true).setMediaCodecSelector(selector))
            .setMediaSourceFactory(mediaSourceFactory)
            .setLoadControl(DefaultLoadControl.Builder().setTargetBufferBytes(48 * 1024 * 1024).build())
            .setReleaseTimeoutMs(Media3BridgePolicy.RELEASE_TIMEOUT_MS)
            .setDetachSurfaceTimeoutMs(500)
            .build()
        player = native
        fun active() = !disposed && callbacks.accepts(ticket) && player === native && eventOpenId == openId
        native.addListener(object : Player.Listener {
            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                if (!active()) return
                if (Media3PlaybackContract.shouldClearPlayIntent(playWhenReady, reason)) {
                    desiredPlaying = false
                }
            }
            override fun onEvents(player: Player, events: Player.Events) {
                if (!active()) return
                val chapterPeriodChanged = updateChapterPeriod(native)
                if (chapterPeriodChanged || events.contains(Player.EVENT_TRACKS_CHANGED)) {
                    for (group in player.currentTracks.groups.take(128)) {
                        for (index in 0 until minOf(group.length, 128)) {
                            collectChapters(group.getTrackFormat(index).metadata)
                        }
                    }
                }
                applyPendingTracks()
                emitState()
                scheduleTick()
            }
            override fun onMetadata(metadata: Metadata) {
                if (!active()) return
                updateChapterPeriod(native)
                collectChapters(metadata)
                emitState()
            }
            override fun onPlayerError(error: PlaybackException) {
                if (!active()) return
                if (Media3BridgePolicy.shouldRetryPrimaryWithoutExternalAudio(
                        externalAudioCount = open.audioTracks.size,
                        alreadyRetried = externalAudioFallbackApplied,
                    )
                ) {
                    // A merged child can fail after its successful network
                    // probe (period mismatch, demuxing, or a later request).
                    // Retry this same primary once without optional audio so a
                    // bad sidecar cannot strand otherwise playable video. A
                    // genuine primary failure is surfaced by the next error.
                    externalAudioFallbackApplied = true
                    val fallback = open.copy(audioTracks = emptyList())
                    request = fallback
                    audioSelection = "auto"
                    trackOverrides.clear()
                    groupIds.clear()
                    val position = native.currentPosition.coerceAtLeast(0)
                    native.setMediaSource(
                        buildMediaSource(fallback, mediaSourceFactory),
                        position,
                    )
                    native.prepare()
                    native.playWhenReady = desiredPlaying && foreground
                    emitState()
                    scheduleTick()
                    return
                }
                terminalError = Media3BridgePolicy.errorCode(error.errorCodeName)
                desiredPlaying = false
                handler.removeCallbacks(tick)
                emitState("error")
            }
        })
        native.addAnalyticsListener(object : AnalyticsListener {
            override fun onVideoDecoderInitialized(eventTime: AnalyticsListener.EventTime, name: String, initializedTimestampMs: Long, initializationDurationMs: Long) {
                if (active()) decoderName = Media3BridgePolicy.safeDecoderName(name)
            }
            override fun onRenderedFirstFrame(eventTime: AnalyticsListener.EventTime, output: Any, renderTimeMs: Long) {
                if (!active()) return
                firstFrameAfterMs = firstFrameAfterMs ?: (SystemClock.elapsedRealtime() - openStartedMs).coerceAtLeast(0)
                emitState()
            }
        })
        native.setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(), true)
        native.setHandleAudioBecomingNoisy(true)
        native.volume = volume
        native.setPlaybackSpeed(rate)
        applyOptions()
        view?.player = native
        native.setMediaSource(buildMediaSource(open, mediaSourceFactory), startMs)
        native.prepare()
        native.playWhenReady = desiredPlaying && foreground
        emitState()
        scheduleTick()
    }

    private fun buildMediaSource(
        open: OpenRequest,
        factory: DefaultMediaSourceFactory,
    ): MediaSource {
        val primarySource = factory.createMediaSource(mediaItem(open))
        return if (open.audioTracks.isEmpty()) {
            primarySource
        } else {
            val audioSources = open.audioTracks.mapIndexed { index, audio ->
                FilteringMediaSource(
                    factory.createMediaSource(
                        MediaItem.Builder()
                            .setMediaId("media3-audio-$id-${open.openId}-${index + 1}")
                            .setUri(Uri.parse(audio.uri))
                            .setMimeType(audio.mimeType)
                            .build(),
                    ),
                    C.TRACK_TYPE_AUDIO,
                )
            }
            MergingMediaSource(
                true,
                true,
                primarySource,
                *audioSources.toTypedArray(),
            )
        }
    }

    private fun mediaItem(open: OpenRequest): MediaItem = MediaItem.Builder()
        // IDs deliberately contain no URL, title, account or source identity.
        .setMediaId("media3-$id-${open.openId}")
        .setUri(Uri.parse(open.uri))
        .setMimeType(open.mimeType)
        .setClippingConfiguration(Media3PlaybackContract.clipping(open.endMs))
        .setSubtitleConfigurations(open.subtitles.map {
            MediaItem.SubtitleConfiguration.Builder(Uri.parse(it.uri))
                .setId(it.id).setLabel(it.title).setLanguage(it.language)
                .setMimeType(it.mimeType)
                .setSelectionFlags(if (it.id == subtitleSelection) C.SELECTION_FLAG_DEFAULT else 0)
                .build()
        }).build()

    fun play() { desiredPlaying = true; player?.playWhenReady = foreground; scheduleTick(); emitState() }
    fun pause() { desiredPlaying = false; player?.pause(); emitState() }
    fun seek(positionMs: Long) { player?.seekTo(request?.endMs?.let { minOf(positionMs, it) } ?: positionMs); emitState() }
    fun setRate(value: Float) { rate = value; player?.setPlaybackSpeed(value); emitState() }
    fun setVolume(value: Float) { volume = value; player?.volume = value; emitState() }
    fun stop() { cancelScreenshot(); desiredPlaying = false; player?.pause(); player?.stop(); handler.removeCallbacks(tick); emitState() }
    fun setForeground(value: Boolean) {
        if (!value) cancelScreenshot()
        foreground = value
        player?.playWhenReady = desiredPlaying && value
        scheduleTick()
        emitState()
    }

    fun setDecoderMode(mode: String) {
        require(mode in setOf("hardware", "software"))
        if (mode == decoderMode) return
        val mime = player?.videoFormat?.sampleMimeType
        if (mode == "software" && request != null && mime == null) {
            throw UnsupportedOperationException("software_decoder_not_yet_known")
        }
        if (mode == "software" && mime != null &&
            MediaCodecSelector.DEFAULT.getDecoderInfos(mime, false, false).none { it.softwareOnly }) {
            throw UnsupportedOperationException("software_decoder_unavailable")
        }
        val open = request
        val position = player?.currentPosition?.coerceAtLeast(0) ?: 0
        if (open != null) releasePlayer()
        decoderMode = mode
        if (open != null) createPlayer(open, position)
    }

    fun setOptions(patch: Map<*, *>) {
        require(patch.keys.all { it is String })
        patch["fit"]?.let { require(it in setOf("contain", "cover", "fill")) }
        patch["subtitleSize"]?.let { require(Media3BridgePolicy.number(it, 8.0, 100.0) != null) }
        patch["subtitlePosition"]?.let { require(Media3BridgePolicy.number(it, 0.0, 100.0) != null) }
        for (key in listOf("subtitleColor", "subtitleBackground")) patch[key]?.let {
            require(Media3BridgePolicy.integer(it, Int.MIN_VALUE.toLong(), 0xffffffffL) != null)
        }
        patch["subtitleBold"]?.let { require(it is Boolean) }
        for (key in listOf("audioLanguage", "subtitleLanguage")) patch[key]?.let {
            require(it is String && Regex("^[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{2,8}){0,2}$").matches(it))
        }
        patch.forEach { (key, value) -> options[key as String] = value }
        applyOptions()
    }

    private fun applyOptions() {
        player?.let { native ->
            val tracks = native.trackSelectionParameters.buildUpon()
            (options["audioLanguage"] as? String)?.let(tracks::setPreferredAudioLanguage)
            (options["subtitleLanguage"] as? String)?.let(tracks::setPreferredTextLanguage)
            tracks.setSelectUndeterminedTextLanguage(true)
            native.trackSelectionParameters = tracks.build()
        }
        view?.let { surface ->
            surface.resizeMode = when (options["fit"]) {
                "cover" -> AspectRatioFrameLayout.RESIZE_MODE_ZOOM
                "fill" -> AspectRatioFrameLayout.RESIZE_MODE_FILL
                else -> AspectRatioFrameLayout.RESIZE_MODE_FIT
            }
            surface.subtitleView?.apply {
                // Keep native cue positioning, styled text and bitmap captions.
                setApplyEmbeddedStyles(true)
                (options["subtitleSize"] as? Number)?.let { setFixedTextSize(TypedValue.COMPLEX_UNIT_SP, it.toFloat()) }
                (options["subtitlePosition"] as? Number)?.let { setBottomPaddingFraction(((100f - it.toFloat()) / 100f).coerceIn(0f, 0.9f)) }
                setStyle(CaptionStyleCompat(
                    (options["subtitleColor"] as? Number)?.toInt() ?: Color.WHITE,
                    (options["subtitleBackground"] as? Number)?.toInt() ?: Color.TRANSPARENT,
                    Color.TRANSPARENT, CaptionStyleCompat.EDGE_TYPE_OUTLINE, Color.BLACK,
                    if (options["subtitleBold"] == true) Typeface.DEFAULT_BOLD else Typeface.DEFAULT,
                ))
            }
        }
    }

    fun attach(surface: PlayerView) {
        if (view === surface) return
        cancelScreenshot()
        view?.player = null
        view = surface
        surface.player = player
        applyOptions()
    }
    fun detach(surface: PlayerView) {
        if (view === surface) cancelScreenshot()
        surface.player = null
        if (view === surface) view = null
    }

    fun addSubtitle(raw: Map<*, *>): Map<String, Any?> {
        val open = requireNotNull(request)
        require(open.subtitles.size < Media3BridgePolicy.MAX_SIDECARS)
        val sid = "sidecar:${++nextSidecar}"
        val sidecar = parseSidecar(raw, sid)
        (raw["trackId"] as? String)?.takeIf { it.length <= 16_384 }?.let { sidecarAliases[it] = sid }
        val select = raw["select"] as? Boolean ?: true
        if (select) subtitleSelection = sid
        val updated = open.copy(subtitles = open.subtitles + sidecar)
        request = updated
        player?.let { native ->
            val position = native.currentPosition.coerceAtLeast(0)
            val sourceFactory = requireNotNull(activeMediaSourceFactory) {
                "media_source_unavailable"
            }
            native.setMediaSource(
                buildMediaSource(updated, sourceFactory),
                position,
            )
            native.prepare()
            native.playWhenReady = desiredPlaying && foreground
        }
        return mapOf("trackId" to sid)
    }

    private fun parseSidecar(raw: Map<*, *>, sid: String): Sidecar {
        val explicitMime = raw["mimeType"] as? String
        var dataMime: String? = null
        var uri = raw["uri"] as? String
        val data = raw["data"]
        if (data != null) {
            val bytes = when (data) { is ByteArray -> data; is String -> data.toByteArray(Charsets.UTF_8); else -> throw IllegalArgumentException("invalid_subtitle") }
            require(bytes.isNotEmpty() && bytes.size <= Media3BridgePolicy.MAX_SIDECAR_BYTES)
            val mime = explicitMime ?: Media3BridgePolicy.subtitleMime(bytes)
            dataMime = mime
            uri = "data:$mime;base64,${Base64.encodeToString(bytes, Base64.NO_WRAP)}"
        } else require(uri != null && Media3BridgePolicy.supportedUri(uri))
        val finalUri = requireNotNull(uri)
        val extension = Uri.parse(finalUri).lastPathSegment?.substringAfterLast('.')?.lowercase()
        val mime = explicitMime ?: dataMime ?: when (extension) {
            "vtt" -> MimeTypes.TEXT_VTT
            "ass", "ssa" -> MimeTypes.TEXT_SSA
            "ttml", "xml" -> MimeTypes.APPLICATION_TTML
            else -> if (data is String && data.startsWith("WEBVTT")) MimeTypes.TEXT_VTT else MimeTypes.APPLICATION_SUBRIP
        }
        require(mime in setOf(MimeTypes.TEXT_VTT, MimeTypes.APPLICATION_SUBRIP, MimeTypes.TEXT_SSA, MimeTypes.APPLICATION_TTML))
        fun label(key: String, max: Int) = (raw[key] as? String)?.take(max)?.replace(Regex("[\\p{Cc}&&[^\\t]]"), "")
        return Sidecar(sid, finalUri, label("title", 160), label("language", 32), mime)
    }

    private fun parseAudioSidecar(raw: Map<*, *>): AudioSidecar {
        val uri = raw["uri"] as? String ?: throw IllegalArgumentException("invalid_audio_sidecar")
        require(Media3BridgePolicy.ownedLoopbackAudioUri(uri))
        val mime = requireNotNull(Media3BridgePolicy.externalAudioMime(raw["mimeType"] as? String)) {
            "invalid_audio_sidecar_mime"
        }
        fun label(key: String, max: Int) = (raw[key] as? String)
            ?.take(max)?.replace(Regex("[\\p{Cc}&&[^\\t]]"), "")
        return AudioSidecar(
            uri,
            label("title", 160),
            label("language", 32),
            if (mime == "application/x-mpegurl") MimeTypes.APPLICATION_M3U8 else mime,
        )
    }

    fun setTrack(value: String, type: Int) {
        val actual = if (type == C.TRACK_TYPE_TEXT) sidecarAliases[value]
            ?: request?.subtitles?.firstOrNull { it.uri == value }?.id ?: value else value
        require(actual in setOf("no", "auto") || Media3BridgePolicy.validTrackId(actual))
        if (actual !in setOf("no", "auto")) {
            require(if (type == C.TRACK_TYPE_AUDIO) actual.startsWith("audio/") else actual.startsWith("subtitle/") || actual.startsWith("sidecar:"))
            player?.let { updateTrackOverrides(it.currentTracks) }
            val pendingSidecar = type == C.TRACK_TYPE_TEXT && request?.subtitles?.any { it.id == actual } == true
            if (!trackOverrides.containsKey(actual) && !pendingSidecar) throw UnsupportedOperationException("track_unavailable")
        }
        if (type == C.TRACK_TYPE_AUDIO) audioSelection = actual else subtitleSelection = actual
        applyPendingTracks()
        emitState()
    }

    private fun applyPendingTracks() {
        val native = player ?: return
        updateTrackOverrides(native.currentTracks)
        val builder = native.trackSelectionParameters.buildUpon()
        for ((type, selection) in listOf(C.TRACK_TYPE_AUDIO to audioSelection, C.TRACK_TYPE_TEXT to subtitleSelection)) {
            builder.setTrackTypeDisabled(type, selection == "no")
            if (selection in setOf("auto", "no")) builder.clearOverridesOfType(type)
            else trackOverrides[selection]?.let { builder.setOverrideForType(it) }
        }
        val parameters = builder.build()
        if (parameters != native.trackSelectionParameters) native.trackSelectionParameters = parameters
    }

    private fun trackId(group: Tracks.Group, index: Int): String {
        val format = group.getTrackFormat(index)
        if (group.type == C.TRACK_TYPE_TEXT) {
            Media3BridgePolicy.sidecarTrackId(
                format.id,
                request?.subtitles?.map { it.id } ?: emptyList(),
                primaryWrappedForExternalAudio = request?.audioTracks?.isNotEmpty() == true,
            )
                ?.let { return it }
        }
        val gid = groupIds.idFor(group.mediaTrackGroup)
        return "${if (group.type == C.TRACK_TYPE_AUDIO) "audio" else "subtitle"}/g$gid/t$index"
    }

    private fun externalAudio(group: Tracks.Group): AudioSidecar? {
        if (group.type != C.TRACK_TYPE_AUDIO) return null
        val childIndex = Media3BridgePolicy.mergedChildIndex(group.mediaTrackGroup.id)
            ?: return null
        if (childIndex <= 0) return null
        return request?.audioTracks?.getOrNull(childIndex - 1)
    }

    private fun updateTrackOverrides(tracks: Tracks) {
        trackOverrides.clear()
        for (group in tracks.groups.take(128)) {
            if (group.type !in setOf(C.TRACK_TYPE_AUDIO, C.TRACK_TYPE_TEXT)) continue
            for (index in 0 until minOf(group.length, 128)) {
                if (group.isTrackSupported(index)) trackOverrides[trackId(group, index)] = TrackSelectionOverride(group.mediaTrackGroup, index)
            }
        }
    }

    private fun trackState(native: ExoPlayer): Map<String, Any?> {
        val audio = arrayListOf<Map<String, Any?>>()
        val subtitle = arrayListOf<Map<String, Any?>>()
        var selectedAudio = if (audioSelection == "no") "no" else "auto"
        var selectedSubtitle = "no"
        for (group in native.currentTracks.groups.take(128)) {
            if (group.type !in setOf(C.TRACK_TYPE_AUDIO, C.TRACK_TYPE_TEXT)) continue
            for (index in 0 until minOf(group.length, 128)) {
                val format = group.getTrackFormat(index)
                val tid = trackId(group, index)
                val externalAudio = externalAudio(group)
                val entry = linkedMapOf<String, Any?>("id" to tid, "title" to (externalAudio?.title ?: format.label)?.take(160), "language" to (externalAudio?.language ?: format.language)?.take(32), "codec" to (Media3BridgePolicy.codec(format.sampleMimeType) ?: format.sampleMimeType?.take(64)), "supported" to group.isTrackSupported(index))
                entry["isDefault"] = format.selectionFlags and C.SELECTION_FLAG_DEFAULT != 0
                if (format.channelCount > 0) entry["channels"] = format.channelCount
                if (format.sampleRate > 0) entry["sampleRate"] = format.sampleRate
                if (group.type == C.TRACK_TYPE_AUDIO) { audio.add(entry); if (group.isTrackSelected(index)) selectedAudio = tid }
                else { subtitle.add(entry); if (group.isTrackSelected(index)) selectedSubtitle = tid }
            }
        }
        return mapOf("tracks" to mapOf("audio" to audio, "subtitle" to subtitle), "selectedAudio" to selectedAudio, "selectedSubtitle" to selectedSubtitle)
    }

    fun emitState(type: String = "state") {
        if (disposed) return
        val native = player
        val state = linkedMapOf<String, Any?>(
            "id" to id, "openId" to openId, "generation" to eventGeneration, "type" to type,
            "positionMs" to (native?.currentPosition?.coerceAtLeast(0) ?: 0L),
            "durationMs" to (native?.duration?.takeIf { it > 0 } ?: 0L),
            "bufferMs" to (native?.totalBufferedDuration?.coerceAtLeast(0) ?: 0L),
            "playing" to (native != null && Media3PlaybackContract.playing(
                native.playWhenReady, native.playbackState, native.playbackSuppressionReason, terminalError != null,
            )),
            "buffering" to (native?.playbackState == Player.STATE_BUFFERING),
            "completed" to (native?.playbackState == Player.STATE_ENDED),
            "width" to (native?.videoSize?.width ?: 0), "height" to (native?.videoSize?.height ?: 0),
            "renderedFirstFrame" to (firstFrameAfterMs != null),
            "rate" to rate.toDouble(), "volume" to volume.toDouble(),
            "metrics" to metrics(),
            "chapters" to chapterState(),
        )
        native?.videoFormat?.frameRate?.takeIf { it.isFinite() && it > 0 }?.let { state["sourceFps"] = it.toDouble() }
        if (native != null) state.putAll(trackState(native))
        terminalError?.let { state["error"] = it }
        emit(state)
    }

    private fun metrics(): Map<String, Any?> {
        val native = player ?: return emptyMap()
        val result = linkedMapOf<String, Any?>()
        decoderName?.let { result["decoderName"] = it }
        val mime = native.videoFormat?.sampleMimeType
        if (mime != null && decoderName != null) {
            runCatching { MediaCodecSelector.DEFAULT.getDecoderInfos(mime, false, false).firstOrNull { it.name == decoderName } }.getOrNull()?.let {
                if (it.softwareOnly) result["activeHwdec"] = "no"
                else if (it.hardwareAccelerated) result["activeHwdec"] = "mediacodec"
            }
        }
        firstFrameAfterMs?.let { result["firstFrameAfterMs"] = it }
        if (externalAudioFallbackApplied) result["externalAudioFallback"] = true
        Media3BridgePolicy.codec(native.videoFormat?.sampleMimeType)?.let { result["codec"] = it }
        Media3BridgePolicy.codec(native.audioFormat?.sampleMimeType)?.let { result["audioCodec"] = it }
        native.videoFormat?.frameRate?.takeIf { it.isFinite() && it > 0 }?.let { result["sourceFps"] = it.toDouble() }
        native.videoFormat?.bitrate?.takeIf { it > 0 }?.let { result["videoBitrate"] = it }
        native.audioFormat?.bitrate?.takeIf { it > 0 }?.let { result["audioBitrate"] = it }
        native.videoSize.width.takeIf { it > 0 }?.let { result["width"] = it }
        native.videoSize.height.takeIf { it > 0 }?.let { result["height"] = it }
        result["bufferSeconds"] = native.totalBufferedDuration.coerceAtLeast(0) / 1000.0
        native.videoDecoderCounters?.let { counters ->
            counters.ensureUpdated()
            result["droppedFrames"] = counters.droppedBufferCount
            result["renderedFrames"] = counters.renderedOutputBufferCount
            result["skippedFrames"] = counters.skippedOutputBufferCount
            result["decoderInitCount"] = counters.decoderInitCount
        }
        return result
    }

    private fun collectChapters(metadata: Metadata?) {
        if (metadata == null || chapterPeriodUid == null) return
        for (index in 0 until minOf(metadata.length(), 256)) {
            val chapter = metadata[index] as? Chapter ?: continue
            if (chapter.isHidden || chapter.startTimeMs < 0) continue
            if (chapters.size >= 256 && !chapters.containsKey(chapter.startTimeMs)) continue
            chapters[chapter.startTimeMs] = chapter.title?.value?.take(160)
                ?.replace(Regex("[\\p{Cc}]"), "")
        }
    }

    private fun updateChapterPeriod(native: ExoPlayer): Boolean {
        val timeline = native.currentTimeline
        val uid = if (timeline.isEmpty) null else timeline.getUidOfPeriod(native.currentPeriodIndex)
        if (uid == chapterPeriodUid) return false
        chapterPeriodUid = uid
        chapters.clear()
        return true
    }

    private fun chapterState(): List<Map<String, Any?>> {
        val native = player ?: return emptyList()
        if (native.currentTimeline.isEmpty) return emptyList()
        if (chapterPeriodUid != native.currentTimeline.getUidOfPeriod(native.currentPeriodIndex)) return emptyList()
        // Also handles a later DASH period and a clipped/sliding window.
        val periodOffsetMs = native.currentTimeline.getPeriod(native.currentPeriodIndex, Timeline.Period())
            .positionInWindowMs
        return chapters.entries.mapIndexedNotNull { index, (startMs, title) ->
            val position = Media3BridgePolicy.chapterPositionSeconds(startMs, periodOffsetMs)
            if (position == null) null else mapOf("time" to position, "title" to (title?.takeIf(String::isNotBlank) ?: "Chapter ${index + 1}"))
        }
    }

    fun readProperty(property: String): Any? {
        val metric = when (property) {
            "hwdec-current" -> "activeHwdec"
            "frame-drop-count" -> "droppedFrames"
            "current-tracks/video/decoder" -> "decoderName"
            "current-tracks/video/codec" -> "codec"
            "current-tracks/audio/codec" -> "audioCodec"
            "container-fps" -> "sourceFps"
            "demuxer-cache-duration" -> "bufferSeconds"
            "video-bitrate" -> "videoBitrate"
            "audio-bitrate" -> "audioBitrate"
            else -> property
        }
        return when (property) {
            "video-params/w" -> player?.videoSize?.width?.takeIf { it > 0 }?.toString()
            "video-params/h" -> player?.videoSize?.height?.takeIf { it > 0 }?.toString()
            else -> metrics()[metric]?.toString()
        }
    }

    fun screenshot(format: String, reply: (ByteArray?) -> Unit) {
        require(format in setOf("image/jpeg", "image/png"))
        val attached = view
        val source = attached?.videoSurfaceView
        val native = player
        val size = source?.let { Media3BridgePolicy.screenshotSize(it.width, it.height) }
        if (disposed || !foreground || native == null || firstFrameAfterMs == null || size == null) {
            reply(null)
            return
        }
        when (source) {
            is TextureView -> {
                val bitmap = if (source.isAvailable) source.getBitmap(size.first, size.second) else null
                reply(bitmap?.let { encodeScreenshot(it, format) })
            }
            is SurfaceView -> {
                // Keep allocation bounded to one outstanding copy per player, even
                // when its result has already been cancelled by lifecycle changes.
                if (pendingScreenshot != null || !source.holder.surface.isValid) {
                    reply(null)
                    return
                }
                val bitmap = Bitmap.createBitmap(size.first, size.second, Bitmap.Config.ARGB_8888)
                val capture = Media3ScreenshotResult(reply)
                pendingScreenshot = capture
                try {
                    // This overload is available on API 24, including supported Fire OS devices.
                    PixelCopy.request(source, bitmap, { status ->
                        if (pendingScreenshot === capture) pendingScreenshot = null
                        val current = capture.isPending && !disposed && foreground &&
                            player === native && view === attached && attached.videoSurfaceView === source
                        val bytes = if (status == PixelCopy.SUCCESS && current) {
                            encodeScreenshot(bitmap, format)
                        } else {
                            bitmap.recycle()
                            null
                        }
                        capture.complete(bytes)
                    }, screenshotHandler)
                } catch (_: Exception) {
                    if (pendingScreenshot === capture) pendingScreenshot = null
                    bitmap.recycle()
                    capture.complete(null)
                }
            }
            else -> reply(null)
        }
    }

    private fun encodeScreenshot(bitmap: Bitmap, format: String): ByteArray? {
        return try {
            ByteArrayOutputStream().use { output ->
                if (!bitmap.compress(if (format == "image/png") Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG, 65, output)) return null
                output.toByteArray().takeIf { it.size <= Media3BridgePolicy.SCREENSHOT_MAX_BYTES }
            }
        } catch (_: Exception) {
            null
        } finally { bitmap.recycle() }
    }

    private fun cancelScreenshot() { pendingScreenshot?.complete(null) }

    private fun scheduleTick() {
        handler.removeCallbacks(tick)
        if (!disposed && foreground && terminalError == null && player != null) handler.postDelayed(tick, 250)
    }

    private fun releasePlayer(requireImmediateCompletion: Boolean = true) {
        if (releaseThread != null) {
            if (playbackThreadAlive && requireImmediateCompletion) {
                throw Media3ReleasePendingException()
            }
            return
        }
        cancelScreenshot()
        callbacks.invalidate() // Before detach/release can enqueue events.
        handler.removeCallbacks(tick)
        val old = player
        player = null
        runCatching { view?.player = null }
        val client = httpClient
        httpClient = null
        activeMediaSourceFactory = null
        client?.dispatcher?.cancelAll()
        try {
            // Media3 performs codec teardown on its playback thread and bounds
            // the main-looper wait with the configured release timeout. The
            // default Builder gives this player its own playback thread; that
            // thread ending is the public, observable completion barrier.
            if (old != null) {
                val ownedPlaybackThread = old.playbackLooper.thread
                releaseThread = ownedPlaybackThread
                Media3ProcessReleaseSafety.track(ownedPlaybackThread)
                try {
                    old.release()
                } catch (_: RuntimeException) {
                    releaseRequiredWaitState = true
                }
                if (ownedPlaybackThread.isAlive) {
                    releaseRequiredWaitState = true
                    if (requireImmediateCompletion) {
                        throw Media3ReleasePendingException()
                    }
                } else {
                    releaseThread = null
                }
            }
        } finally {
            client?.connectionPool?.evictAll()
            client?.dispatcher?.executorService?.shutdown()
        }
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        try {
            releasePlayer(requireImmediateCompletion = false)
        } finally {
            view = null
            request = null
            sidecarAliases.clear()
            trackOverrides.clear()
            groupIds.clear()
        }
    }

    val playbackThreadAlive: Boolean
        get() {
            val thread = releaseThread ?: return false
            if (thread.isAlive) return true
            releaseThread = null
            return false
        }

    val releaseRequiredWait: Boolean get() = releaseRequiredWaitState

    val releaseCanBeReaped: Boolean get() = disposed && !playbackThreadAlive
}

/** Prevents any bridge instance from overlapping an owned playback thread. */
private object Media3ProcessReleaseSafety {
    private val playbackThreads = Media3PlaybackThreadRegistry<Thread>(Thread::isAlive)

    fun track(thread: Thread) = playbackThreads.track(thread)
    fun allReleased(): Boolean = playbackThreads.allReleased()
}

/** Closed marker: never carries a native stack message, URL, or headers. */
private class Media3ReleasePendingException : RuntimeException()
