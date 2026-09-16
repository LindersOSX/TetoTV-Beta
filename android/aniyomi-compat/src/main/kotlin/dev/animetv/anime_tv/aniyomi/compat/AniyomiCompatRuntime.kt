package dev.animetv.anime_tv.aniyomi.compat

import aniyomi.lib.m3u8server.M3u8ServerManager
import android.app.Application
import dev.mihon.injekt.patchInjekt
import eu.kanade.tachiyomi.animesource.AnimeCatalogueSource
import eu.kanade.tachiyomi.animesource.AnimeSource
import eu.kanade.tachiyomi.animesource.AnimeSourceFactory
import eu.kanade.tachiyomi.animesource.model.FetchType
import eu.kanade.tachiyomi.animesource.model.SAnime
import eu.kanade.tachiyomi.animesource.model.SEpisode
import eu.kanade.tachiyomi.animesource.model.Track
import eu.kanade.tachiyomi.animesource.model.Video
import eu.kanade.tachiyomi.animesource.online.AnimeHttpSource
import eu.kanade.tachiyomi.animesource.online.ParsedAnimeHttpSource
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.network.JavaScriptEngine
import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.SourceFactory
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.online.HttpSource
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import okhttp3.Headers
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeoutException
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.addSingleton

/**
 * Real source-api entry point. MUST only be called by the disposable isolated worker.
 * No real context/service/application is registered, and no APK code executes in the UI process.
 * The worker owns the hard deadline/process kill, APK verification and loader lifetime.
 */
object AniyomiCompatRuntime {
    const val RUNTIME_REVISION = "aniyomi-39e9a749-tetotv-subset-8"
    const val MAX_LAZY_HOSTERS_PER_REQUEST = 8
    const val MAX_HOSTER_LOAD_MS = 2_000L

    @Synchronized
    fun execute(
        loader: ClassLoader,
        descriptor: JSONObject,
        request: JSONObject,
        broker: (JSONObject) -> JSONObject,
    ): JSONObject {
        M3u8ServerManager.resetBridgeDiagnostics()
        val transport = BrokerTransport(broker)
        val result = try {
            AniyomiRuntimeFailure.atStage("runtime_setup") {
                executeChecked(loader, descriptor, request, transport)
            }
        } catch (failure: AniyomiRuntimeFailure) {
            // A normal HTTP response can be followed by awaitSuccess/parser
            // failure. Preserve its inner operation stage and add only the
            // transport's fixed, bounded context in that failure case.
            throw failure.withFallbackBrokerContext(transport.lastResponseContext())
        }
        transport.lastResponseContext()?.let { context ->
            result.put("broker_redirect_count", context.redirectCount)
                .put("broker_response_size_bucket", context.responseSizeBucket)
                .put("broker_status_class", context.statusClass)
        }
        return boundedResult(result)
    }

    private fun executeChecked(
        loader: ClassLoader,
        descriptor: JSONObject,
        request: JSONObject,
        transport: BrokerTransport,
    ): JSONObject {
        val kind = descriptor.getString("kind")
        val api = descriptor.getString("apiVersion")
        require((kind == "anime" && api in setOf("14", "16")) ||
            (kind == "manga" && api in setOf("1.4", "1.5"))) {
            "Unsupported Aniyomi API version"
        }
        patchInjekt()
        // Current extension helpers ask Injekt for Application to obtain source
        // preferences. Never expose the worker's real Application/context; this
        // base-less capability contains only bounded, invocation-local stores.
        val preferenceApplication = AniyomiPreferenceApplication()
        Injekt.addSingleton<Application>(preferenceApplication)
        Injekt.addSingleton(NetworkHelper(transport))
        Injekt.addSingleton(JavaScriptEngine(preferenceApplication))
        // Keep the declared service key exactly `Json`. Current extension
        // helpers resolve this singleton during class initialization for both
        // response parsing and JSON request-body construction.
        Injekt.addSingleton<Json>(Json { ignoreUnknownKeys = true; explicitNulls = false })
        try {
            val classes = descriptor.getJSONArray("classNames")
            require(classes.length() in 1..32) { "Invalid provider entrypoint count" }
            val sources = ArrayList<Any>()
            for (index in 0 until classes.length()) {
                val type = AniyomiRuntimeFailure.atStage("class_load") { loader.loadClass(classes.getString(index)) }
                val instance = AniyomiRuntimeFailure.atStage("source_construct") { type.getDeclaredConstructor().newInstance() }
                val candidates: List<Any> = AniyomiRuntimeFailure.atStage("source_factory") { when (instance) {
                    is AnimeSourceFactory -> instance.createSources()
                    is SourceFactory -> instance.createSources()
                    is AnimeSource, is Source -> listOf(instance)
                    else -> throw UnsupportedOperationException("Not an Aniyomi source or source factory")
                } }
                require(candidates.size + sources.size <= MAX_SOURCES) { "Too many provider sources" }
                candidates.forEach { source ->
                    require((kind == "anime" && source is AnimeSource) || (kind == "manga" && source is Source)) {
                        "Provider kind differs from its manifest"
                    }
                    sources.add(source)
                }
            }
            require(sources.isNotEmpty()) { "Provider factory returned no sources" }
            AniyomiRuntimeFailure.atStage("source_describe") {
                require(sources.map(::sourceId).distinct().size == sources.size) { "Duplicate provider source IDs" }
            }
            if (request.getString("operation") == "sources") {
                return AniyomiRuntimeFailure.atStage("source_describe") {
                    boundedResult(JSONObject().put("sources", JSONArray(sources.map { sourceDescriptor(it, kind) })))
                }
            }
            val requestedId = request.optString("sourceId")
            val source = AniyomiRuntimeFailure.atStage("source_select") { if (requestedId.isBlank() && sources.size == 1) sources.single() else
                sources.singleOrNull { sourceId(it) == requestedId }
                    ?: throw IllegalArgumentException("Select a provider source")
            }
            return AniyomiRuntimeFailure.atStage("source_operation") { runBlocking {
                when (source) {
                    is AnimeSource -> anime(source, api, request)
                    is Source -> manga(source, request)
                    else -> throw UnsupportedOperationException("Unsupported source type")
                }
            } }
        } finally {
            // Drop registered capabilities even on parser/ABI errors. Worker terminates next.
            patchInjekt()
        }
    }

    private fun sourceId(source: Any): String = when (source) {
        is AnimeSource -> source.id.toString()
        is Source -> source.id.toString()
        else -> error("Unsupported source")
    }

    private fun sourceDescriptor(source: Any, kind: String): JSONObject = JSONObject()
        .put("id", sourceId(source)).put("kind", kind)
        .put("name", resultText(when (source) { is AnimeSource -> source.name; is Source -> source.name; else -> "" }, 160))
        .put("lang", resultText(when (source) { is AnimeSource -> source.lang; is Source -> source.lang; else -> "" }, 24))
        .put("baseUrl", resultText(when (source) { is AnimeHttpSource -> source.baseUrl; is HttpSource -> source.baseUrl; else -> "" }, 4096))
        .put("supportsLatest", when (source) { is AnimeSource -> source.supportsLatest; is CatalogueSource -> source.supportsLatest; else -> false })

    private suspend fun anime(source: AnimeSource, api: String, request: JSONObject): JSONObject {
        val input = SAnime.create().apply { url = request.optString("url"); title = request.optString("title") }
        return when (request.getString("operation")) {
            "search" -> atOperationStage("source_search") {
                val catalogue = source as? AnimeCatalogueSource ?: unsupported()
                val resultPage = catalogue.getSearchAnime(
                    page(request),
                    request.optString("query"),
                    catalogue.getFilterList(),
                )
                val selection = boundedPrefix(resultPage.animes, MAX_SEARCH_ITEMS, MAX_ORIGINAL_SEARCH_ITEMS)
                JSONObject().put("items", JSONArray(selection.items.map { animeItem(it, source) }))
                    .put("hasNextPage", resultPage.hasNextPage)
                    .putResultCounts(selection.originalCount, selection.items.size, selection.truncatedCount)
            }
            "details" -> atOperationStage("source_details") {
                val detail = source.getAnimeDetails(input)
                if (runCatching { detail.url }.getOrDefault("").isBlank()) detail.url = input.url
                if (runCatching { detail.title }.getOrDefault("").isBlank()) detail.title = input.title
                JSONObject().put("item", animeItem(detail, source))
            }
            "seasons" -> atOperationStage("source_seasons") {
                val selection = selectSeasons(source.getSeasonList(input), request)
                JSONObject().put("seasons", JSONArray(selection.seasons.map { animeItem(it, source) }))
                    .put("originalCount", selection.originalCount)
                    .put("returnedCount", selection.seasons.size)
                    .put("filteredCount", selection.filteredCount)
                    .put("truncatedCount", selection.truncatedCount)
            }
            "chapters", "episodes" -> atOperationStage("source_episodes") {
                val selection = selectEpisodes(source.getEpisodeList(input), request)
                JSONObject().put("chapters", JSONArray(selection.episodes.map {
                    JSONObject().put("url", resultText(it.url, 4096)).put("name", resultText(it.name, 512))
                        .put("number", finite(it.episode_number)).put("dateUpload", it.date_upload)
                        .put("scanlator", optionalResultText(it.scanlator, 256))
                })).put("originalCount", selection.originalCount)
                    .put("returnedCount", selection.episodes.size)
                    .put("filteredCount", selection.filteredCount)
                    .put("truncatedCount", selection.truncatedCount)
            }
            "videos" -> atOperationStage("source_videos") {
                val episode = SEpisode.create().apply { url = input.url; name = input.title }
                // API 16 was transitional: providers that did not override the
                // new hoster surface still use the deprecated episode -> videos
                // contract. Mirror Aniyomi's EpisodeLoader override detection.
                val selection = if (api == "14" || !hasHosterFlow(source)) {
                    resolveLegacyVideos(source, episode)
                } else {
                    resolveHosterVideos(source, episode, request)
                }
                val result = ArrayList<JSONObject>()
                var discarded = selection.discardedCount
                var truncated = selection.truncatedCount
                var discardedTracks = 0
                for (video in selection.videos) {
                    if (result.size >= MAX_VIDEOS) {
                        truncated++
                        continue
                    }
                    try {
                        val serialized = videoItem(video)
                        result.add(serialized.item)
                        discardedTracks += serialized.discardedTrackCount
                    } catch (_: AniyomiResultLimitExceeded) {
                        discarded++
                    } catch (_: IllegalArgumentException) {
                        discarded++
                    } catch (_: UnsupportedOperationException) {
                        discarded++
                    } catch (_: SecurityException) {
                        discarded++
                    }
                }
                if (result.isEmpty() && discarded > 0) {
                    throw UnsupportedOperationException("provider_video_rows_unsupported")
                }
                JSONObject().put("videos", JSONArray(result))
                    .put("discardedVideoCount", discarded)
                    .put("truncatedCount", truncated)
                    .put("originalCount", selection.originalCount)
                    .put("returnedCount", result.size)
                    .put("discardedTrackCount", discardedTracks)
                    .put("localHlsBridgeCount", M3u8ServerManager.consumeBridgeCount().coerceAtMost(MAX_VIDEOS))
                    .put("truncatedHosterCount", selection.truncatedHosterCount)
                    .put("discardedHosterCount", selection.discardedHosterCount)
                    .put("deferredHosterCount", selection.deferredHosterCount)
                    .put("originalHosterCount", selection.originalHosterCount)
                    .put("visitedHosterCount", selection.visitedHosterCount)
                    .put("lazyHosterCount", selection.lazyHosterCount)
                    .put("attemptedLazyHosterCount", selection.attemptedLazyHosterCount)
                    .put("resolvedLazyHosterCount", selection.resolvedLazyHosterCount)
                    .put("failedLazyHosterCount", selection.failedLazyHosterCount)
            }
            else -> unsupported()
        }
    }

    private data class VideoSelection(
        val videos: List<Video>,
        val originalCount: Int,
        val discardedCount: Int = 0,
        val truncatedCount: Int = 0,
        val truncatedHosterCount: Int = 0,
        val discardedHosterCount: Int = 0,
        val deferredHosterCount: Int = 0,
        val originalHosterCount: Int = 0,
        val visitedHosterCount: Int = 0,
        val lazyHosterCount: Int = 0,
        val attemptedLazyHosterCount: Int = 0,
        val resolvedLazyHosterCount: Int = 0,
        val failedLazyHosterCount: Int = 0,
    )

    private data class SerializedVideo(
        val item: JSONObject,
        val discardedTrackCount: Int,
    )

    private data class SerializedTracks(
        val items: JSONArray,
        val discardedCount: Int,
    )

    private fun hasHosterFlow(source: AnimeSource): Boolean {
        var current: Class<*> = source.javaClass
        val stopTypes = if (source is AnimeHttpSource) {
            setOf(ParsedAnimeHttpSource::class.java, AnimeHttpSource::class.java, AnimeSource::class.java)
        } else {
            setOf(AnimeSource::class.java)
        }
        repeat(MAX_SOURCE_HIERARCHY_DEPTH) {
            if (current in stopTypes) return false
            if (current.declaredMethods.any { method ->
                    !method.isBridge && (
                        method.name == "getHosterList" ||
                            (source is AnimeHttpSource && method.name in HOSTER_PARSER_METHODS)
                        )
                }
            ) {
                return true
            }
            current = current.superclass ?: return false
        }
        return false
    }

    private suspend fun resolveLegacyVideos(source: AnimeSource, episode: SEpisode): VideoSelection {
        val originals = source.getVideoList(episode)
        if (originals.size > MAX_ORIGINAL_VIDEOS) throw AniyomiResultLimitExceeded()
        val ordered = if (source is AnimeHttpSource) source.run { originals.sortVideos() } else originals
        val scanned = ordered.take(MAX_VIDEO_SCAN_ITEMS)
        val resolved = ArrayList<Video>(scanned.size)
        var discarded = 0
        for (video in scanned) {
            val item = resolveLegacyVideo(source, video)
            if (item == null) discarded++ else resolved.add(item)
        }
        return VideoSelection(
            videos = resolved,
            originalCount = originals.size,
            discardedCount = discarded,
            truncatedCount = originals.size - scanned.size,
        )
    }

    /** Flatten the API-16 episode -> hoster -> video flow into the JSON boundary. */
    private suspend fun resolveHosterVideos(
        source: AnimeSource,
        episode: SEpisode,
        request: JSONObject,
    ): VideoSelection {
        val originalHosters = atOperationStage("source_hosters") { source.getHosterList(episode) }
        if (originalHosters.size > MAX_ORIGINAL_HOSTERS) throw AniyomiResultLimitExceeded()
        val orderedHosters = if (source is AnimeHttpSource) source.run { originalHosters.sortHosters() } else originalHosters
        val hosters = orderedHosters.take(MAX_HOSTERS)
        // Upstream Aniyomi leaves `lazy` hosters idle until a user explicitly
        // selects one. TetoTV currently has no hoster picker, so its Dart
        // adapter opts into resolving a small sorted prefix in this same
        // disposable worker invocation. Keeping this request-gated preserves
        // the previous defer-by-default contract for older callers.
        val resolveLazyHosters = request.optBoolean("resolveLazyHosters", false)
        val lazyHosterLimit = if (resolveLazyHosters) {
            request.optInt("lazyHosterLimit", MAX_LAZY_HOSTERS_PER_REQUEST).also {
                require(it in 1..MAX_LAZY_HOSTERS_PER_REQUEST) { "Invalid lazy hoster limit" }
            }
        } else {
            0
        }
        val hosterLoadTimeoutMs = request.optLong("hosterLoadTimeoutMs", MAX_HOSTER_LOAD_MS).also {
            require(it in 1..MAX_HOSTER_LOAD_MS) { "Invalid hoster load timeout" }
        }
        // Classify the entire bounded provider order first. Eager hosters are
        // executed before any opt-in lazy work, but outcomes stay indexed by
        // the provider's sorted order so the flattened result rank is stable.
        val outcomes = MutableList<HosterLoad>(hosters.size) { HosterLoad.Deferred }
        val eager = ArrayList<IndexedHoster>(hosters.size)
        val selectedLazy = ArrayList<IndexedHoster>(lazyHosterLimit)
        for ((index, hoster) in hosters.withIndex()) {
            val indexed = IndexedHoster(index, hoster)
            when {
                !hoster.lazy -> eager.add(indexed)
                selectedLazy.size < lazyHosterLimit -> selectedLazy.add(indexed)
            }
        }
        val schedule = loadHostersBounded(
            source,
            eager + selectedLazy,
            hosterLoadTimeoutMs,
        )
        schedule.outcomes.forEach { (index, outcome) -> outcomes[index] = outcome }
        // Three hostile eager calls can occupy every hard-bounded slot until
        // worker teardown. Eager rows that could not safely be started are
        // failures; unstarted opt-in lazy rows retain Deferred semantics.
        eager.filterNot { it.index in schedule.launchedIndexes }.forEach { indexed ->
            outcomes[indexed.index] = HosterLoad.Failed(hosterTimeoutFailure())
        }

        val result = ArrayList<Video>()
        var originalCount = 0
        var discarded = 0
        var truncated = 0
        var discardedHosters = 0
        var deferredHosters = 0
        var resolvedLazyHosters = 0
        var failedLazyHosters = 0
        var firstHosterFailure: AniyomiRuntimeFailure? = null
        for ((index, outcome) in outcomes.withIndex()) {
            val hoster = hosters[index]
            when (outcome) {
                HosterLoad.Deferred -> deferredHosters++
                is HosterLoad.Failed -> {
                    discardedHosters++
                    if (hoster.lazy) failedLazyHosters++
                    if (firstHosterFailure == null) firstHosterFailure = outcome.failure
                }
                is HosterLoad.Ready -> {
                    if (hoster.lazy) resolvedLazyHosters++
                    val originalVideos = outcome.videos
                    originalCount += originalVideos.size
                    val remainingScan = (MAX_VIDEO_SCAN_ITEMS - result.size - discarded).coerceAtLeast(0)
                    val unresolved = originalVideos.take(remainingScan)
                    truncated += originalVideos.size - unresolved.size
                    for (video in unresolved) {
                        try {
                            val resolved = resolveCurrentVideo(source, video)
                            if (resolved == null) discarded++ else result.add(resolved)
                        } catch (error: Throwable) {
                            rethrowFatal(error)
                            discarded++
                        }
                    }
                }
            }
        }
        if (result.isEmpty() && originalCount == 0 && firstHosterFailure != null) throw firstHosterFailure
        return VideoSelection(
            videos = result,
            originalCount = originalCount,
            discardedCount = discarded,
            truncatedCount = truncated,
            truncatedHosterCount = originalHosters.size - hosters.size,
            discardedHosterCount = discardedHosters,
            deferredHosterCount = deferredHosters,
            originalHosterCount = originalHosters.size,
            visitedHosterCount = hosters.size,
            lazyHosterCount = originalHosters.count { it.lazy },
            attemptedLazyHosterCount = selectedLazy.count { it.index in schedule.launchedIndexes },
            resolvedLazyHosterCount = resolvedLazyHosters,
            failedLazyHosterCount = failedLazyHosters,
        )
    }

    private data class IndexedHoster(
        val index: Int,
        val hoster: eu.kanade.tachiyomi.animesource.model.Hoster,
    )

    private data class FinishedHosterLoad(
        val index: Int,
        val outcome: HosterLoad?,
    )

    private data class ActiveHosterLoad(
        val job: Job,
        val deadlineNanos: Long,
        var timedOut: Boolean = false,
    )

    private data class HosterSchedule(
        val outcomes: Map<Int, HosterLoad>,
        val launchedIndexes: Set<Int>,
    )

    /**
     * Executes the eager-then-lazy queue with a hard cap on live extension
     * calls. A timed-out non-cooperative call keeps occupying its slot until it
     * really exits; this prevents abandoned calls from accumulating across
     * batches. Other slots continue harvesting successful siblings. Once no
     * safe slot can advance, the disposable worker's existing process teardown
     * remains the final containment boundary.
     */
    private suspend fun loadHostersBounded(
        source: AnimeSource,
        hosters: List<IndexedHoster>,
        timeoutMs: Long,
    ): HosterSchedule {
        if (hosters.isEmpty()) return HosterSchedule(emptyMap(), emptySet())
        val pending = java.util.ArrayDeque(hosters)
        val completions = Channel<FinishedHosterLoad>(Channel.UNLIMITED)
        val taskScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val active = HashMap<Int, ActiveHosterLoad>(MAX_PARALLEL_HOSTERS)
        val completed = HashMap<Int, HosterLoad>(hosters.size)
        val launched = HashSet<Int>(hosters.size)

        fun accept(finished: FinishedHosterLoad) {
            val state = active.remove(finished.index) ?: return
            if (!state.timedOut && finished.outcome != null) {
                completed[finished.index] = finished.outcome
            }
        }

        try {
            while (pending.isNotEmpty() || active.isNotEmpty()) {
                while (pending.isNotEmpty() && active.size < MAX_PARALLEL_HOSTERS) {
                    val indexed = pending.removeFirst()
                    val deadlineNanos = System.nanoTime() + timeoutMs * NANOS_PER_MILLISECOND
                    val job = taskScope.launch {
                        val outcome = try {
                            loadHosterVideos(source, indexed.hoster)
                        } catch (_: CancellationException) {
                            null
                        }
                        completions.trySend(FinishedHosterLoad(indexed.index, outcome))
                    }
                    active[indexed.index] = ActiveHosterLoad(job, deadlineNanos)
                    launched.add(indexed.index)
                }

                while (true) {
                    val finished = completions.tryReceive().getOrNull() ?: break
                    accept(finished)
                }

                val now = System.nanoTime()
                active.forEach { (index, state) ->
                    if (!state.timedOut && now >= state.deadlineNanos) {
                        state.timedOut = true
                        completed[index] = HosterLoad.Failed(hosterTimeoutFailure())
                        state.job.cancel()
                    }
                }

                if (pending.isEmpty() && active.values.all { it.timedOut }) break
                if (pending.isNotEmpty() && active.size == MAX_PARALLEL_HOSTERS &&
                    active.values.all { it.timedOut }
                ) break
                if (active.isEmpty() ||
                    pending.isNotEmpty() && active.size < MAX_PARALLEL_HOSTERS
                ) continue

                val nextDeadline = active.values
                    .asSequence()
                    .filterNot { it.timedOut }
                    .minOfOrNull { it.deadlineNanos }
                    ?: break
                val remainingNanos = nextDeadline - System.nanoTime()
                if (remainingNanos <= 0) continue
                val remainingMillis = ((remainingNanos + NANOS_PER_MILLISECOND - 1) /
                    NANOS_PER_MILLISECOND).coerceAtLeast(1)
                withTimeoutOrNull(remainingMillis) { completions.receive() }?.let(::accept)
            }
        } finally {
            // Non-joining cancellation is safe here because this one scheduler
            // never has more than MAX_PARALLEL_HOSTERS extension calls alive.
            taskScope.cancel()
            completions.close()
        }
        return HosterSchedule(completed, launched)
    }

    private fun hosterTimeoutFailure(): AniyomiRuntimeFailure = AniyomiRuntimeFailure.describe(
        TimeoutException("hoster_load_timeout"),
        "source_videos",
    )

    private sealed interface HosterLoad {
        data class Ready(val videos: List<Video>) : HosterLoad
        data class Failed(val failure: AniyomiRuntimeFailure) : HosterLoad
        data object Deferred : HosterLoad
    }

    private suspend fun loadHosterVideos(source: AnimeSource, hoster: eu.kanade.tachiyomi.animesource.model.Hoster): HosterLoad = try {
        val originals = atOperationStage("source_videos") { hoster.videoList ?: source.getVideoList(hoster) }
        if (originals.size > MAX_ORIGINAL_VIDEOS) throw AniyomiResultLimitExceeded()
        val ordered = if (source is AnimeHttpSource) source.run { originals.sortVideos() } else originals
        HosterLoad.Ready(ordered)
    } catch (error: Throwable) {
        if (error is VirtualMachineError || error is ThreadDeath) throw error
        if (error is CancellationException) {
            // A scheduler/worker cancellation makes this coroutine inactive and
            // must propagate to the wrapper's null outcome. A provider-owned
            // withTimeout throws TimeoutCancellationException while this outer
            // hoster job remains active; retain it as a real, isolated hoster
            // failure so successful siblings and lazy-count invariants survive.
            currentCoroutineContext().ensureActive()
        }
        HosterLoad.Failed(
            error as? AniyomiRuntimeFailure ?: AniyomiRuntimeFailure.describe(error, "source_videos"),
        )
    }

    private fun rethrowFatal(error: Throwable) {
        if (error is VirtualMachineError || error is ThreadDeath || error is CancellationException) throw error
    }

    private suspend fun resolveCurrentVideo(source: AnimeSource, video: Video): Video? {
        if (source !is AnimeHttpSource) return video
        var resolved = video
        if (resolved.videoUrl.isBlank() || resolved.videoUrl == "null") {
            @Suppress("DEPRECATION")
            val url = source.getVideoUrl(resolved)
            resolved = resolved.copy(videoUrl = url)
        }
        if (!resolved.initialized) {
            resolved = source.resolveVideo(resolved) ?: return null
            if (!resolved.initialized) resolved = resolved.copy(initialized = true)
        }
        return resolved
    }

    private suspend fun resolveLegacyVideo(source: AnimeSource, video: Video): Video? {
        if ((video.videoUrl.isBlank() || video.videoUrl == "null") && source is AnimeHttpSource) {
            @Suppress("DEPRECATION")
            video.videoUrl = source.getVideoUrl(video)
        }
        return video
    }

    private data class EpisodeSelection(
        val episodes: List<SEpisode>,
        val originalCount: Int,
        val filteredCount: Int,
        val truncatedCount: Int,
    )

    private data class SeasonSelection(
        val seasons: List<SAnime>,
        val originalCount: Int,
        val filteredCount: Int,
        val truncatedCount: Int,
    )

    private fun selectSeasons(seasons: List<SAnime>, request: JSONObject): SeasonSelection {
        if (seasons.size > MAX_ORIGINAL_SEASONS) throw AniyomiResultLimitExceeded()
        val targetSeason = request.getInt("targetSeason")
        require(targetSeason in 0..1_000)
        val candidates = ArrayList<SAnime>(minOf(MAX_SEASON_CANDIDATES, seasons.size))
        var candidateCount = 0
        for (season in seasons) {
            if (!isSeasonCandidate(season, targetSeason)) continue
            candidateCount++
            if (candidates.size < MAX_SEASON_CANDIDATES) candidates.add(season)
        }
        return SeasonSelection(
            seasons = candidates,
            originalCount = seasons.size,
            filteredCount = seasons.size - candidateCount,
            truncatedCount = candidateCount - candidates.size,
        )
    }

    private fun isSeasonCandidate(season: SAnime, targetSeason: Int): Boolean {
        val number = season.season_number
        if (number.isFinite() && number >= 0.0) return number == targetSeason.toDouble()
        val label = season.title
        if (label.length !in 1..MAX_SEASON_LABEL_CHARS) return false
        return explicitSeason(label) == targetSeason
    }

    private fun selectEpisodes(episodes: List<SEpisode>, request: JSONObject): EpisodeSelection {
        if (episodes.size > MAX_ORIGINAL_EPISODES) throw AniyomiResultLimitExceeded()
        if (!request.has("targetEpisode")) {
            if (episodes.size > MAX_CHAPTERS) throw AniyomiResultLimitExceeded()
            return EpisodeSelection(episodes, episodes.size, filteredCount = 0, truncatedCount = 0)
        }
        val targetEpisode = request.getDouble("targetEpisode")
        val targetSeason = request.optInt("targetSeason", -1).takeIf { request.has("targetSeason") }
        val candidates = ArrayList<SEpisode>(minOf(MAX_EPISODE_CANDIDATES, episodes.size))
        var candidateCount = 0
        for (episode in episodes) {
            if (!isEpisodeCandidate(episode, targetEpisode.toInt(), targetSeason)) continue
            candidateCount++
            if (candidates.size < MAX_EPISODE_CANDIDATES) candidates.add(episode)
        }
        return EpisodeSelection(
            episodes = candidates,
            originalCount = episodes.size,
            filteredCount = episodes.size - candidateCount,
            truncatedCount = candidateCount - candidates.size,
        )
    }

    private fun isEpisodeCandidate(episode: SEpisode, targetEpisode: Int, targetSeason: Int?): Boolean {
        val label = episode.name
        if (targetSeason != null && explicitSeason(label)?.let { it != targetSeason } == true) return false
        val number = episode.episode_number
        if (number.isFinite() && number > 0f) return number == targetEpisode.toFloat()
        // Some API-14/16 extensions leave the structured number at its -1
        // sentinel and put the only usable identity in the label. Retain only
        // explicit, bounded label matches; Dart still performs the final
        // season-aware identity and ambiguity check.
        if (label.length !in 1..MAX_EPISODE_LABEL_CHARS) return false
        return EPISODE_LABEL_PATTERNS.any { pattern ->
            pattern.findAll(label).any { it.groupValues[1].toIntOrNull() == targetEpisode }
        }
    }

    /** Only reject an explicitly conflicting season marker; unlabeled rows remain candidates. */
    private fun explicitSeason(label: String): Int? {
        val prefix = Regex("(?i)(?:\\bseason\\s*|\\bs)([0-9]{1,3})\\b").find(label)?.groupValues?.get(1)
        val ordinal = Regex("(?i)\\b([0-9]{1,3})(?:st|nd|rd|th)\\s+season\\b").find(label)?.groupValues?.get(1)
        return (prefix ?: ordinal)?.toIntOrNull()
    }

    private suspend fun manga(source: Source, request: JSONObject): JSONObject {
        val input = SManga.create().apply { url = request.optString("url"); title = request.optString("title") }
        return when (request.getString("operation")) {
            "search" -> atOperationStage("source_search") {
                val catalogue = source as? CatalogueSource ?: unsupported()
                val page = catalogue.getSearchManga(page(request), request.optString("query"), catalogue.getFilterList())
                val selection = boundedPrefix(page.mangas, MAX_SEARCH_ITEMS, MAX_ORIGINAL_SEARCH_ITEMS)
                JSONObject().put("items", JSONArray(selection.items.map { mangaItem(it, source) }))
                    .put("hasNextPage", page.hasNextPage)
                    .putResultCounts(selection.originalCount, selection.items.size, selection.truncatedCount)
            }
            "details" -> atOperationStage("source_details") {
                val detail = source.getMangaDetails(input)
                if (runCatching { detail.url }.getOrDefault("").isBlank()) detail.url = input.url
                if (runCatching { detail.title }.getOrDefault("").isBlank()) detail.title = input.title
                JSONObject().put("item", mangaItem(detail, source))
            }
            "chapters" -> atOperationStage("source_chapters") {
                val chapters = bounded(source.getChapterList(input), MAX_CHAPTERS)
                JSONObject().put("chapters", JSONArray(chapters.map {
                    JSONObject().put("url", resultText(it.url, 4096)).put("name", resultText(it.name, 512))
                        .put("number", finite(it.chapter_number)).put("dateUpload", it.date_upload)
                        .put("scanlator", optionalResultText(it.scanlator, 256))
                })).putResultCounts(chapters.size, chapters.size, truncated = 0)
            }
            "pages" -> atOperationStage("source_pages") {
                val chapter = SChapter.create().apply { url = input.url; name = input.title }
                val pages = bounded(source.getPageList(chapter), MAX_PAGES)
                val mapped = pages.map { page ->
                    val httpSource = source as? HttpSource
                    if (page.imageUrl.isNullOrBlank()) {
                        page.imageUrl = atOperationStage("source_image_url") {
                            httpSource?.getImageUrl(page) ?: unsupported()
                        }
                    }
                    val imageRequest = httpSource?.runtimeImageRequest(page)
                    require(imageRequest == null || imageRequest.method == "GET") {
                        "Unsupported provider media request method"
                    }
                    val url = imageRequest?.url?.toString() ?: page.imageUrl ?: unsupported()
                    JSONObject().put("index", page.index).put("url", mediaUrl(url))
                        .put("headers", privateImageHeaders(imageRequest?.headers))
                }
                JSONObject().put("pages", JSONArray(mapped))
                    .putResultCounts(pages.size, mapped.size, truncated = 0)
            }
            else -> unsupported()
        }
    }

    private fun animeItem(item: SAnime, source: AnimeSource): JSONObject = JSONObject()
        .put("url", resultText(item.url, 4096)).put("title", resultText(item.title, 512))
        .put("thumbnailUrl", artworkUrl(item.thumbnail_url, (source as? AnimeHttpSource)?.baseUrl))
        .put("description", optionalResultText(item.description, 16 * 1024))
        .put("author", optionalResultText(item.author, 512)).put("artist", optionalResultText(item.artist, 512))
        .put("genre", optionalResultText(item.genre, 1024)).put("status", item.status)
        .put("fetchType", if (item.fetch_type == FetchType.Seasons) "seasons" else "episodes")
        .put("seasonNumber", finite(item.season_number.toFloat()))

    private fun mangaItem(item: SManga, source: Source): JSONObject = JSONObject()
        .put("url", resultText(item.url, 4096)).put("title", resultText(item.title, 512))
        .put("thumbnailUrl", artworkUrl(item.thumbnail_url, (source as? HttpSource)?.baseUrl))
        // The trusted host consumes these when it creates an opaque cover
        // grant. Provider transport metadata is never returned to Flutter.
        .put("thumbnailHeaders", privateImageHeaders((source as? HttpSource)?.headers))
        .put("description", optionalResultText(item.description, 16 * 1024))
        .put("author", optionalResultText(item.author, 512)).put("artist", optionalResultText(item.artist, 512))
        .put("genre", optionalResultText(item.genre, 1024)).put("status", item.status)

    private fun videoItem(video: Video): SerializedVideo {
        if (video.mpvArgs.isNotEmpty() || video.ffmpegStreamArgs.isNotEmpty() || video.ffmpegVideoArgs.isNotEmpty()) {
            throw UnsupportedOperationException("Provider native player and FFmpeg arguments are forbidden")
        }
        val subtitles = tracks(video.subtitleTracks)
        val audio = tracks(video.audioTracks)
        val item = boundedRow(JSONObject().put("url", mediaUrl(video.videoUrl)).put("quality", resultText(video.videoTitle, 160))
            .put("headers", safeHeaders(video.headers)).put("subtitleTracks", subtitles.items)
            .put("audioTracks", audio.items), MAX_VIDEO_ROW_BYTES)
        return SerializedVideo(item, subtitles.discardedCount + audio.discardedCount)
    }

    private fun tracks(tracks: List<Track>): SerializedTracks {
        val items = ArrayList<JSONObject>()
        var discarded = 0
        for (track in bounded(tracks, MAX_TRACKS)) {
            try {
                items.add(JSONObject().put("url", mediaUrl(track.url)).put("lang", resultText(track.lang, 64)))
            } catch (_: Exception) {
                discarded++
            }
        }
        return SerializedTracks(JSONArray(items), discarded)
    }

    private fun safeHeaders(headers: Headers?): JSONObject = JSONObject().apply {
        headers?.names()?.forEach { name ->
            // Only playback headers, never cookies, credentials, Host or proxy controls.
            val values = headers.values(name)
            if (values.isEmpty()) return@forEach
            when (name.lowercase()) {
                "cache-control" -> Unit // Host-side cache policy is intentionally not propagated.
                // These fields are singletons for playback. OkHttp's effective
                // value is the last one; joining duplicates creates an invalid
                // Referer/Origin URI and can break otherwise valid providers.
                "referer", "origin", "user-agent" ->
                    put(name, resultText(values.last(), 2048))
                // Only explicitly list-valued negotiation fields are joined.
                "accept", "accept-language" ->
                    put(name, resultText(values.joinToString(", "), 2048))
                // Browser-shaped media CDNs commonly require these Fetch
                // Metadata request headers. They carry no credentials or
                // routing authority, but validate their small standard value
                // domains before allowing them across the worker boundary.
                "sec-fetch-dest" -> put(
                    name,
                    safeFetchMetadataValue(values.last(), setOf("audio", "empty", "video")),
                )
                "sec-fetch-mode" -> put(
                    name,
                    safeFetchMetadataValue(values.last(), setOf("cors", "navigate", "no-cors", "same-origin")),
                )
                "sec-fetch-site" -> put(
                    name,
                    safeFetchMetadataValue(values.last(), setOf("cross-site", "none", "same-origin", "same-site")),
                )
                else -> throw UnsupportedOperationException("Unsupported provider media header")
            }
        }
        require(toString().length <= 8192) { "Provider media headers exceed limit" }
    }

    private fun safeFetchMetadataValue(value: String, allowed: Set<String>): String {
        val normalized = resultText(value, 32).trim().lowercase()
        require(normalized in allowed) { "Invalid provider fetch metadata header" }
        return normalized
    }

    /**
     * Private image transport headers are consumed by the trusted host. Drop
     * unrelated source headers instead of making otherwise valid catalogs
     * fail, and retain provider-owned credentials only inside this boundary.
     */
    private fun privateImageHeaders(headers: Headers?): JSONObject = JSONObject().apply {
        headers?.names()?.forEach { name ->
            when (name.lowercase()) {
                "authorization", "cookie", "referer", "origin", "user-agent",
                "accept", "accept-language", "range" ->
                    put(
                        name,
                        resultText(
                            headers.values(name).joinToString(if (name.equals("cookie", true)) "; " else ", "),
                            2048,
                        ),
                    )
            }
        }
        require(length() <= 12 && toString().length <= 8192) { "Provider image headers exceed limit" }
    }

    private fun mediaUrl(value: String): String {
        val url = value.toHttpUrlOrNull() ?: unsupported()
        if (!url.isHttps || url.username.isNotEmpty() || url.password.isNotEmpty() || value.length > 8192) unsupported()
        // The trusted native host must also apply grant/host/public-DNS checks to these URLs.
        return url.toString()
    }

    /**
     * Many otherwise compatible sources expose relative or scheme-relative
     * artwork. Resolve it while the source base URL is still available, then
     * let the trusted host apply its public-DNS and port policy. Invalid
     * optional artwork is omitted rather than invalidating catalog identity.
     */
    private fun artworkUrl(value: String?, baseUrl: String?): String? {
        val raw = optionalResultText(value, 4096)?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val base = baseUrl?.toHttpUrlOrNull()
        val resolved = raw.toHttpUrlOrNull() ?: base?.resolve(raw) ?: return null
        if (!resolved.isHttps || resolved.username.isNotEmpty() || resolved.password.isNotEmpty()) return null
        return resultText(resolved.toString(), 4096)
    }

    private fun page(request: JSONObject): Int = request.optInt("page", 1).also { require(it in 1..10000) }
    private suspend fun <T> atOperationStage(stage: String, action: suspend () -> T): T = try {
        action().also { if (it is JSONObject) boundedResult(it) }
    } catch (error: Throwable) {
        if (error is VirtualMachineError || error is ThreadDeath || error is CancellationException) throw error
        throw AniyomiRuntimeFailure.describe(error, stage)
    }
    private fun finite(value: Float): Double = if (value.isFinite()) value.toDouble() else -1.0
    private fun <T> bounded(items: List<T>, maximum: Int): List<T> =
        items.also { if (it.size > maximum) throw AniyomiResultLimitExceeded() }

    private data class BoundedSelection<T>(
        val items: List<T>,
        val originalCount: Int,
        val truncatedCount: Int,
    )

    private fun <T> boundedPrefix(items: List<T>, maximum: Int, maximumOriginal: Int): BoundedSelection<T> {
        if (items.size > maximumOriginal) throw AniyomiResultLimitExceeded()
        val returned = items.take(maximum)
        return BoundedSelection(returned, items.size, items.size - returned.size)
    }

    private fun JSONObject.putResultCounts(original: Int, returned: Int, truncated: Int): JSONObject =
        put("originalCount", original).put("returnedCount", returned).put("truncatedCount", truncated)

    private fun boundedResult(result: JSONObject): JSONObject = result.also {
        if (it.toString().toByteArray(Charsets.UTF_8).size > MAX_RESULT_BYTES) throw AniyomiResultLimitExceeded()
    }

    private fun boundedRow(result: JSONObject, maximum: Int): JSONObject = result.also {
        if (it.toString().toByteArray(Charsets.UTF_8).size > maximum) throw AniyomiResultLimitExceeded()
    }

    private fun resultText(value: String, maximum: Int): String = value.also {
        if (it.length > maximum || '\u0000' in it || it.toByteArray(Charsets.UTF_8).size > maximum) {
            throw AniyomiResultLimitExceeded()
        }
    }

    private fun optionalResultText(value: String?, maximum: Int): String? = value?.let { resultText(it, maximum) }
    private fun unsupported(): Nothing = throw UnsupportedOperationException("Operation is outside the experimental compatibility subset")
    private const val MAX_SOURCES = 32
    private const val MAX_SEARCH_ITEMS = 100
    private const val MAX_ORIGINAL_SEARCH_ITEMS = 10_000
    private const val MAX_CHAPTERS = 2000
    private const val MAX_ORIGINAL_SEASONS = 1_000
    private const val MAX_SEASON_CANDIDATES = 16
    private const val MAX_SEASON_LABEL_CHARS = 512
    private const val MAX_ORIGINAL_EPISODES = 100_000
    private const val MAX_EPISODE_CANDIDATES = 64
    private const val MAX_EPISODE_LABEL_CHARS = 512
    private const val MAX_PAGES = 1000
    private const val MAX_HOSTERS = 64
    private const val MAX_PARALLEL_HOSTERS = 3
    private const val NANOS_PER_MILLISECOND = 1_000_000L
    private const val MAX_ORIGINAL_HOSTERS = 1024
    private const val MAX_VIDEOS = 32
    private const val MAX_VIDEO_SCAN_ITEMS = 128
    private const val MAX_ORIGINAL_VIDEOS = 4096
    const val MAX_AGGREGATE_VIDEOS = MAX_HOSTERS * MAX_ORIGINAL_VIDEOS
    private const val MAX_VIDEO_ROW_BYTES = 24 * 1024
    private const val MAX_TRACKS = 16
    private const val MAX_RESULT_BYTES = 160 * 1024
    private const val MAX_SOURCE_HIERARCHY_DEPTH = 64
    private val HOSTER_PARSER_METHODS = setOf("hosterListRequest", "hosterListParse")
    private val EPISODE_LABEL_PATTERNS = listOf(
        Regex("(?i)\\bs[0-9]{1,3}\\s*e([0-9]{1,6})(?![0-9])"),
        Regex("(?i)\\b[0-9]{1,3}x([0-9]{1,6})(?![0-9])"),
        Regex("(?i)(?:\\bepisode|\\bep\\.?|\\be)\\s*#?\\s*0*([0-9]{1,6})(?![0-9])"),
        Regex("^\\s*0*([0-9]{1,6})(?:\\s*v[0-9]+)?\\s*$", RegexOption.IGNORE_CASE),
        Regex("(?i)\\s[-–—]\\s*0*([0-9]{1,6})(?:\\s*v[0-9]+)?(?:\\s|$)"),
    )
}

internal class AniyomiResultLimitExceeded : IllegalArgumentException("provider_result_limit")
