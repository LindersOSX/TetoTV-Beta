package tetotv.fixture

import android.app.Application
import android.content.Context
import dev.animetv.anime_tv.aniyomi.compat.AniyomiCompatRuntime
import dev.animetv.anime_tv.aniyomi.compat.AniyomiBrokerInvalidResponse
import dev.animetv.anime_tv.aniyomi.compat.AniyomiBrokerNetworkFailure
import dev.animetv.anime_tv.aniyomi.compat.AniyomiBrokerPolicyDenied
import dev.animetv.anime_tv.aniyomi.compat.AniyomiBrokerUnsupportedCapability
import dev.animetv.anime_tv.aniyomi.compat.AniyomiRuntimeFailure

import eu.kanade.tachiyomi.animesource.AnimeCatalogueSource
import eu.kanade.tachiyomi.animesource.AnimeSource
import eu.kanade.tachiyomi.animesource.AnimeSourceFactory
import eu.kanade.tachiyomi.animesource.model.AnimeFilterList
import eu.kanade.tachiyomi.animesource.model.AnimesPage
import eu.kanade.tachiyomi.animesource.model.FetchType
import eu.kanade.tachiyomi.animesource.model.Hoster
import eu.kanade.tachiyomi.animesource.model.SAnime
import eu.kanade.tachiyomi.animesource.model.SEpisode
import eu.kanade.tachiyomi.animesource.model.Track
import eu.kanade.tachiyomi.animesource.model.Video
import eu.kanade.tachiyomi.animesource.online.AnimeHttpSource
import eu.kanade.tachiyomi.network.GET
import eu.kanade.tachiyomi.network.POST
import eu.kanade.tachiyomi.network.awaitSuccess
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.online.ParsedHttpSource
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Request
import okhttp3.Response
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import org.jsoup.nodes.Document
import org.jsoup.nodes.Element
import org.junit.Assert.*
import org.junit.Test
import rx.Observable
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class AniyomiCompatRuntimeTest {
    private fun execute(
        type: Class<*>,
        kind: String,
        operation: String,
        apiVersion: String = if (kind == "anime") "14" else "1.4",
        requestFields: Map<String, Any> = emptyMap(),
        broker: (JSONObject) -> JSONObject = { error("Unexpected network") },
    ): JSONObject {
        val descriptor = JSONObject().put("kind", kind).put("apiVersion", apiVersion)
            .put("classNames", JSONArray().put(type.name))
        val request = JSONObject().put("operation", operation).put("query", "fixture")
            .put("url", "/series").put("title", "Fixture title").put("page", 1)
        requestFields.forEach(request::put)
        return AniyomiCompatRuntime.execute(javaClass.classLoader!!, descriptor, request, broker)
    }

    @Test fun factoryEnumeratesRealSourceAndStableId() {
        val result = execute(FixtureAnimeFactory::class.java, "anime", "sources")
        assertEquals("42", result.getJSONArray("sources").getJSONObject(0).getString("id"))
    }

    @Test fun kickAssStyleMultiwordSearchUsesRealAsyncBrokerChainAndCanContinueToVideos() {
        var searchCalls = 0
        val search = execute(
            KickAssStyleSearchFixture::class.java, "anime", "search",
            requestFields = mapOf("query" to "One Piece"),
        ) { envelope ->
            searchCalls++
            assertEquals("POST", envelope.getString("method"))
            assertEquals("https://kaa.lt/api/fsearch", envelope.getString("url"))
            val headers = envelope.getJSONObject("headers")
            // The APK concatenates the query verbatim. Trusted broker policy
            // owns space escaping; the transport must not silently drop it.
            assertEquals("https://kaa.lt/search?q=One Piece", headers.getString("Referer"))
            assertFalse(headers.has("Host"))
            val body = JSONObject(String(Base64.getDecoder().decode(envelope.getString("bodyBase64")), Charsets.UTF_8))
            assertEquals("One Piece", body.getString("query"))
            assertEquals(1, body.getInt("page"))
            response("{\"title\":\"One Piece\"}", envelope)
        }
        assertEquals(1, searchCalls)
        assertEquals("One Piece", search.getJSONArray("items").getJSONObject(0).getString("title"))
        assertEquals("2xx", search.getString("broker_status_class"))
        val details = execute(KickAssStyleSearchFixture::class.java, "anime", "details") {
            response("{\"title\":\"One Piece\"}", it)
        }
        assertEquals("One Piece", details.getJSONObject("item").getString("title"))
        val episodes = execute(KickAssStyleSearchFixture::class.java, "anime", "episodes") {
            response("fixture episode", it)
        }
        assertEquals(1, episodes.getJSONArray("chapters").length())
        val videos = execute(KickAssStyleSearchFixture::class.java, "anime", "videos") {
            response("https://media.example.test/fixture.mp4", it)
        }
        assertEquals(1, videos.getJSONArray("videos").length())
    }

    @Test fun legacyRxSearchAndDetailsRunThroughCoroutineBridge() {
        val search = execute(FixtureAnimeFactory::class.java, "anime", "search")
        assertEquals("Fixture anime", search.getJSONArray("items").getJSONObject(0).getString("title"))
        val detail = execute(FixtureAnimeFactory::class.java, "anime", "details").getJSONObject("item")
        assertEquals("Fixture anime", detail.getString("title"))
        assertEquals("A generated test fixture", detail.getString("description"))
    }

    @Test fun kickAssStyleNonAsciiAliasFailsBeforeBrokerWithoutStaleHttpContext() {
        var brokerCalls = 0
        val failure = assertThrows(AniyomiRuntimeFailure::class.java) {
            execute(
                KickAssStyleSearchFixture::class.java, "anime", "search",
                requestFields = mapOf("query" to "ワンピース"),
            ) {
                brokerCalls++
                error("Header construction must fail before dispatch")
            }
        }
        // The pinned APK concatenates the alias into Headers.Builder.add.
        // OkHttp rejects non-ASCII before our broker can canonicalize Referer.
        // The adapter can try a distinct catalog alias, not weaken headers.
        assertEquals(0, brokerCalls)
        assertEquals("source_search", failure.stage)
        assertEquals("invalid_input", failure.category)
        assertEquals("extension_execution_failed", failure.errorCode)
        assertNull(failure.brokerFailure)
        assertNull(failure.brokerRedirectCount)
        assertNull(failure.brokerResponseSizeBucket)
        assertNull(failure.brokerStatusClass)
        assertFalse(failure.toString().contains("ワンピース"))
    }

    @Test fun configuredJsonIsAvailableDuringExtensionConstruction() {
        val result = execute(JsonConstructingAnimeSource::class.java, "anime", "search")
        assertEquals(
            "Configured JSON",
            result.getJSONArray("items").getJSONObject(0).getString("title"),
        )
    }

    @Test fun relativeAndSchemeRelativeArtworkResolveAgainstTheSourceBaseUrl() {
        val result = execute(RelativeArtworkAnimeHttpSource::class.java, "anime", "search")
        val items = result.getJSONArray("items")
        assertEquals("https://fixture.example.test/images/relative.jpg", items.getJSONObject(0).getString("thumbnailUrl"))
        assertEquals("https://cdn.example.test/scheme-relative.jpg", items.getJSONObject(1).getString("thumbnailUrl"))
        assertTrue(items.getJSONObject(2).isNull("thumbnailUrl"))
    }

    @Test fun episodesAndLegacyVideoConstructorProduceTypedResults() {
        val episodes = execute(FixtureAnimeFactory::class.java, "anime", "episodes").getJSONArray("chapters")
        assertEquals(1.0, episodes.getJSONObject(0).getDouble("number"), 0.0)
        val video = execute(FixtureAnimeFactory::class.java, "anime", "videos").getJSONArray("videos").getJSONObject(0)
        assertEquals("https://media.example.test/fixture.mp4", video.getString("url"))
        assertEquals("720p", video.getString("quality"))
    }

    @Test fun targetedEpisodeSelectionFindsRowsBeyondFullReplyLimit() {
        val result = execute(
            LongEpisodeAnimeSource::class.java,
            "anime",
            "episodes",
            requestFields = mapOf("targetEpisode" to 4500),
        )
        val episodes = result.getJSONArray("chapters")
        assertEquals(1, episodes.length())
        assertEquals(4500.0, episodes.getJSONObject(0).getDouble("number"), 0.0)
        assertEquals(5000, result.getInt("originalCount"))
        assertEquals(1, result.getInt("returnedCount"))
        assertEquals(4999, result.getInt("filteredCount"))
        assertEquals(0, result.getInt("truncatedCount"))
    }

    @Test fun targetedEpisodeSelectionRetainsExplicitLabelWhenStructuredNumberIsSentinel() {
        val result = execute(
            LabelOnlyLongEpisodeAnimeSource::class.java,
            "anime",
            "episodes",
            requestFields = mapOf("targetEpisode" to 3500, "targetSeason" to 2),
        )
        val episodes = result.getJSONArray("chapters")
        assertEquals(1, episodes.length())
        assertEquals("Season 2 Episode 3500", episodes.getJSONObject(0).getString("name"))
        assertEquals(5001, result.getInt("originalCount"))
        assertEquals(5000, result.getInt("filteredCount"))
    }

    @Test fun targetedEpisodeSelectionReportsCandidateTruncationWithoutOversizedReply() {
        val result = execute(
            DuplicateEpisodeAnimeSource::class.java,
            "anime",
            "episodes",
            requestFields = mapOf("targetEpisode" to 12),
        )
        assertEquals(64, result.getJSONArray("chapters").length())
        assertEquals(80, result.getInt("originalCount"))
        assertEquals(64, result.getInt("returnedCount"))
        assertEquals(0, result.getInt("filteredCount"))
        assertEquals(16, result.getInt("truncatedCount"))
    }

    @Test fun untargetedOversizedEpisodeListFailsWithExplicitResponseLimitCode() {
        val failure = assertThrows(AniyomiRuntimeFailure::class.java) {
            execute(LongEpisodeAnimeSource::class.java, "anime", "episodes")
        }
        assertEquals("extension_result_too_large", failure.errorCode)
        assertEquals("source_episodes", failure.stage)
    }

    @Test fun seasonContainersExposeMetadataAndSelectTheExactRequestedSeason() {
        val detail = execute(
            SeasonContainerAnimeSource::class.java,
            "anime",
            "details",
            apiVersion = "16",
        ).getJSONObject("item")
        assertEquals("seasons", detail.getString("fetchType"))

        val result = execute(
            SeasonContainerAnimeSource::class.java,
            "anime",
            "seasons",
            apiVersion = "16",
            requestFields = mapOf("targetSeason" to 275),
        )
        val seasons = result.getJSONArray("seasons")
        assertEquals(1, seasons.length())
        assertEquals("/series/season/275", seasons.getJSONObject(0).getString("url"))
        assertEquals(275.0, seasons.getJSONObject(0).getDouble("seasonNumber"), 0.0)
        assertEquals(300, result.getInt("originalCount"))
        assertEquals(1, result.getInt("returnedCount"))
        assertEquals(299, result.getInt("filteredCount"))
        assertEquals(0, result.getInt("truncatedCount"))
    }

    @Test fun oversizedSeasonCollectionsFailWithAnExplicitBoundedResultCode() {
        val failure = assertThrows(AniyomiRuntimeFailure::class.java) {
            execute(
                OversizedSeasonAnimeSource::class.java,
                "anime",
                "seasons",
                apiVersion = "16",
                requestFields = mapOf("targetSeason" to 2),
            )
        }
        assertEquals("extension_result_too_large", failure.errorCode)
        assertEquals("source_seasons", failure.stage)
    }

    @Test fun mixedInvalidVideoRowsDoNotDropLaterValidRows() {
        val result = execute(MixedVideoAnimeSource::class.java, "anime", "videos")
        val videos = result.getJSONArray("videos")
        assertEquals(1, videos.length())
        assertEquals("https://media.example.test/valid.mp4", videos.getJSONObject(0).getString("url"))
        assertEquals(3, result.getInt("originalCount"))
        assertEquals(1, result.getInt("returnedCount"))
        assertEquals(2, result.getInt("discardedVideoCount"))
        assertEquals(0, result.getInt("truncatedCount"))
    }

    @Test fun playbackHeadersUseLastSingletonAndJoinOnlyNegotiationLists() {
        val result = execute(DuplicatePlaybackHeaderAnimeSource::class.java, "anime", "videos")
        val headers = result.getJSONArray("videos").getJSONObject(0).getJSONObject("headers")

        assertEquals("https://embed.example.test/final", headers.getString("Referer"))
        assertEquals("https://media.example.test", headers.getString("Origin"))
        assertEquals("final-agent", headers.getString("User-Agent"))
        assertEquals("video/*, application/vnd.apple.mpegurl", headers.getString("Accept"))
        assertEquals("en-US, ja-JP", headers.getString("Accept-Language"))
        assertEquals("empty", headers.getString("Sec-Fetch-Dest"))
        assertEquals("cors", headers.getString("Sec-Fetch-Mode"))
        assertEquals("same-site", headers.getString("Sec-Fetch-Site"))
        assertFalse(headers.has("Cache-Control"))
    }

    @Test fun invalidWorkerLocalTracksDoNotDiscardAnOtherwiseValidVideo() {
        val result = execute(MixedTrackVideoAnimeSource::class.java, "anime", "videos")
        val videos = result.getJSONArray("videos")
        assertEquals(1, videos.length())
        val video = videos.getJSONObject(0)
        assertEquals("https://media.example.test/with-tracks.mp4", video.getString("url"))
        assertEquals(1, video.getJSONArray("subtitleTracks").length())
        assertEquals(
            "https://media.example.test/spanish.vtt",
            video.getJSONArray("subtitleTracks").getJSONObject(0).getString("url"),
        )
        assertEquals(1, video.getJSONArray("audioTracks").length())
        assertEquals(2, result.getInt("discardedTrackCount"))
        assertFalse(result.toString().contains("file:///"))
        assertFalse(result.toString().contains("http://"))
    }

    @Test fun legacyHttpSourcesApplyProviderVideoOrdering() {
        val result = execute(SortedLegacyVideoAnimeSource::class.java, "anime", "videos")
        val videos = result.getJSONArray("videos")
        assertEquals(2, videos.length())
        assertEquals("preferred", videos.getJSONObject(0).getString("quality"))
        assertEquals("fallback", videos.getJSONObject(1).getString("quality"))
    }

    @Test fun longVideoListsAreBoundedAndReportTruncationInsteadOfDroppingEverything() {
        val result = execute(LongVideoAnimeSource::class.java, "anime", "videos")
        assertEquals(32, result.getJSONArray("videos").length())
        assertEquals(200, result.getInt("originalCount"))
        assertEquals(32, result.getInt("returnedCount"))
        assertEquals(168, result.getInt("truncatedCount"))
    }

    @Test fun parsedMangaUsesBrokerInsteadOfSockets() {
        var called = 0
        val result = execute(FixtureMangaSource::class.java, "manga", "search") { request ->
            called++
            assertEquals("https://fixture.example.test/search", request.getString("url"))
            assertEquals("max-age=600", request.getJSONObject("headers").getString("Cache-Control"))
            response("<a class='series' href='/series'>Fixture manga</a><a class='next'></a>", request)
        }
        assertEquals(1, called)
        assertTrue(result.getBoolean("hasNextPage"))
        assertEquals("Fixture manga", result.getJSONArray("items").getJSONObject(0).getString("title"))
    }

    @Test fun brokerPolicyDenialSurvivesTransportAsFixedCause() {
        val failure = assertThrows(AniyomiRuntimeFailure::class.java) {
            execute(FixtureMangaSource::class.java, "manga", "search") {
                throw AniyomiBrokerPolicyDenied()
            }
        }
        assertEquals("source_search", failure.stage)
        assertEquals("security_denied", failure.category)
        assertEquals("unsupported_extension_capability", failure.errorCode)
        assertFalse(failure.toString().contains("http_broker_denied"))
    }

    @Test fun brokerFailureCategoriesRemainDistinctAndPrivacySafe() {
        val cases = listOf(
            AniyomiBrokerNetworkFailure() to "io",
            AniyomiBrokerUnsupportedCapability() to "unsupported_capability",
            AniyomiBrokerInvalidResponse() to "invalid_input",
        )
        for ((brokerFailure, expectedCategory) in cases) {
            val failure = assertThrows(AniyomiRuntimeFailure::class.java) {
                execute(FixtureMangaSource::class.java, "manga", "search") { throw brokerFailure }
            }
            assertEquals("source_search", failure.stage)
            assertEquals(expectedCategory, failure.category)
            assertFalse(failure.toString().contains("http_broker_"))
            assertNull(failure.cause)
        }
    }

    @Test fun normalHttpFailureRetainsOnlyBoundedLastResponseContext() {
        val body = ByteArray(70 * 1024) { 'x'.code.toByte() }
        val failure = assertThrows(AniyomiRuntimeFailure::class.java) {
            execute(FixtureMangaSource::class.java, "manga", "search") { request ->
                JSONObject().put("statusCode", 503)
                    .put("headers", JSONObject().put("Content-Type", "text/html"))
                    .put("url", request.getString("url"))
                    .put("bodyBase64", Base64.getEncoder().encodeToString(body))
                    .put("broker_redirect_count", 2)
            }
        }

        assertEquals("source_search", failure.stage)
        assertEquals("execution", failure.category)
        assertNull(failure.brokerFailure)
        assertEquals(2, failure.brokerRedirectCount)
        assertEquals("64to128k", failure.brokerResponseSizeBucket)
        assertEquals("5xx", failure.brokerStatusClass)
        assertNull(failure.cause)
    }

    @Test fun mangaDetailsChaptersAndPagesUseRealParsers() {
        val detail = execute(FixtureMangaSource::class.java, "manga", "details") {
            response("<h1>Detail title</h1><p>Detail summary</p>", it)
        }.getJSONObject("item")
        assertEquals("Detail title", detail.getString("title"))
        assertEquals("/series", detail.getString("url"))
        val chapters = execute(FixtureMangaSource::class.java, "manga", "chapters") {
            response("<a class='chapter' href='/chapter'>Chapter 1</a>", it)
        }.getJSONArray("chapters")
        assertEquals("/chapter", chapters.getJSONObject(0).getString("url"))
        val pages = execute(FixtureMangaSource::class.java, "manga", "pages") {
            response("<img src='https://images.example.test/1.png'>", it)
        }.getJSONArray("pages")
        assertEquals("https://images.example.test/1.png", pages.getJSONObject(0).getString("url"))
    }

    @Test fun mangaPagesResolveDeferredImageUrlsAndPreserveSafeImageHeaders() {
        val requestedUrls = mutableListOf<String>()
        val pages = execute(DeferredImageMangaSource::class.java, "manga", "pages") { request ->
            requestedUrls += request.getString("url")
            if (requestedUrls.size == 1) {
                response("<div>page list</div>", request)
            } else {
                response("<img src='https://images.example.test/resolved.png'>", request)
            }
        }.getJSONArray("pages")

        assertEquals(
            listOf("https://fixture.example.test/series", "https://fixture.example.test/image-token"),
            requestedUrls,
        )
        val page = pages.getJSONObject(0)
        assertEquals("https://images.example.test/resolved.png", page.getString("url"))
        assertEquals("https://fixture.example.test/reader", page.getJSONObject("headers").getString("Referer"))
        assertEquals("Bearer image-token", page.getJSONObject("headers").getString("Authorization"))
        assertEquals("image_session=private", page.getJSONObject("headers").getString("Cookie"))
        assertFalse(page.getJSONObject("headers").has("X-Ignored-Image-Control"))
        assertFalse(page.getJSONObject("headers").has("Cache-Control"))
    }

    @Test fun mangaCoverHeadersDropUnrelatedSourceControlsWithoutFailingSearch() {
        val result = execute(NoisyCoverHeaderMangaSource::class.java, "manga", "search") { request ->
            assertEquals("drop-at-image-boundary", request.getJSONObject("headers").getString("X-Provider-Noise"))
            response("<a class='series' href='/series'>Fixture manga</a>", request)
        }
        val item = result.getJSONArray("items").getJSONObject(0)
        assertEquals("https://images.example.test/cover.jpg", item.getString("thumbnailUrl"))
        assertFalse(item.getJSONObject("thumbnailHeaders").has("X-Provider-Noise"))
    }

    @Test fun constructionPreferencesUseDefaultsAndRemainInvocationLocal() {
        val first = execute(PreferenceConstructingAnimeSource::class.java, "anime", "sources")
        val second = execute(PreferenceConstructingAnimeSource::class.java, "anime", "sources")
        assertEquals("Preference fixture 1", first.getJSONArray("sources").getJSONObject(0).getString("name"))
        assertEquals("Preference fixture 1", second.getJSONArray("sources").getJSONObject(0).getString("name"))
    }

    @Test fun injectedApplicationDoesNotExposeWorkerFiles() {
        val failure = assertThrows(AniyomiRuntimeFailure::class.java) {
            execute(PrivilegedContextAnimeSource::class.java, "anime", "sources")
        }
        assertEquals("source_construct", failure.stage)
    }

    @Test fun api16FlattensEmbeddedAndDeferredHosterVideos() {
        val videos = execute(
            FixtureApi16AnimeSource::class.java,
            "anime",
            "videos",
            apiVersion = "16",
        ).getJSONArray("videos")
        assertEquals(2, videos.length())
        assertEquals("https://media.example.test/embedded.mp4", videos.getJSONObject(0).getString("url"))
        assertEquals("https://media.example.test/deferred.mp4", videos.getJSONObject(1).getString("url"))
    }

    @Test fun api16FallsBackToDeprecatedEpisodeVideosWhenHostersAreNotOverridden() {
        val result = execute(
            TransitionalApi16AnimeHttpSource::class.java,
            "anime",
            "videos",
            apiVersion = "16",
        )
        val videos = result.getJSONArray("videos")
        assertEquals(1, videos.length())
        assertEquals("https://media.example.test/fixture.mp4", videos.getJSONObject(0).getString("url"))
        assertEquals(1, result.getInt("originalCount"))
        assertEquals(1, result.getInt("returnedCount"))
    }

    @Test fun api16HosterFailuresAreIsolatedLazyHostersDeferredAndLoadsOverlap() {
        ResilientApi16AnimeHttpSource.resetTestState()
        val result = execute(
            ResilientApi16AnimeHttpSource::class.java,
            "anime",
            "videos",
            apiVersion = "16",
        )
        val videos = result.getJSONArray("videos")
        assertEquals(2, videos.length())
        assertEquals("https://media.example.test/success.mp4", videos.getJSONObject(0).getString("url"))
        assertEquals("https://media.example.test/mixed-good.mp4", videos.getJSONObject(1).getString("url"))
        assertEquals(3, result.getInt("originalCount"))
        assertEquals(2, result.getInt("returnedCount"))
        assertEquals(1, result.getInt("discardedVideoCount"))
        assertEquals(1, result.getInt("discardedHosterCount"))
        assertEquals(1, result.getInt("deferredHosterCount"))
        assertEquals(0, result.getInt("truncatedHosterCount"))
        assertTrue(ResilientApi16AnimeHttpSource.maxConcurrentLoads.get() >= 2)
        assertEquals(0, ResilientApi16AnimeHttpSource.lazyLoads.get())
        assertFalse(result.toString().contains("provider-secret"))
    }

    @Test fun api16ExplicitlyResolvesBoundedLazyHostersForFlattenedClients() {
        val result = execute(
            AllLazyApi16AnimeSource::class.java,
            "anime",
            "videos",
            apiVersion = "16",
            requestFields = mapOf(
                "resolveLazyHosters" to true,
                "lazyHosterLimit" to 1,
            ),
        )

        val videos = result.getJSONArray("videos")
        assertEquals(1, videos.length())
        assertEquals("https://media.example.test/lazy-one.mp4", videos.getJSONObject(0).getString("url"))
        assertEquals(2, result.getInt("originalHosterCount"))
        assertEquals(2, result.getInt("visitedHosterCount"))
        assertEquals(2, result.getInt("lazyHosterCount"))
        assertEquals(1, result.getInt("attemptedLazyHosterCount"))
        assertEquals(1, result.getInt("resolvedLazyHosterCount"))
        assertEquals(0, result.getInt("failedLazyHosterCount"))
        assertEquals(1, result.getInt("deferredHosterCount"))
        assertEquals(0, result.getInt("truncatedHosterCount"))
    }

    @Test fun api16ProcessesLaterEagerHosterBeforeLazyHosterCanExhaustItsBudget() {
        LazyFirstBudgetApi16AnimeSource.resetTestState()
        val result = execute(
            LazyFirstBudgetApi16AnimeSource::class.java,
            "anime",
            "videos",
            apiVersion = "16",
            requestFields = mapOf(
                "resolveLazyHosters" to true,
                "lazyHosterLimit" to 1,
                "hosterLoadTimeoutMs" to 100,
            ),
        )

        val videos = result.getJSONArray("videos")
        assertEquals(1, videos.length())
        assertEquals("https://media.example.test/eager-after-lazy.mp4", videos.getJSONObject(0).getString("url"))
        assertTrue(LazyFirstBudgetApi16AnimeSource.eagerLoaded.get())
        assertTrue(LazyFirstBudgetApi16AnimeSource.lazyObservedEagerLoaded.get())
        assertEquals(2, result.getInt("originalHosterCount"))
        assertEquals(2, result.getInt("visitedHosterCount"))
        assertEquals(0, result.getInt("truncatedHosterCount"))
        assertEquals(1, result.getInt("lazyHosterCount"))
        assertEquals(1, result.getInt("attemptedLazyHosterCount"))
        assertEquals(0, result.getInt("resolvedLazyHosterCount"))
        assertEquals(1, result.getInt("failedLazyHosterCount"))
        assertEquals(1, result.getInt("discardedHosterCount"))
        assertEquals(0, result.getInt("deferredHosterCount"))
    }

    @Test fun api16HarvestsFastSiblingWithoutJoiningStalledHoster() {
        StalledSiblingApi16AnimeSource.resetTestState()
        val startedAt = System.nanoTime()
        val result = try {
            execute(
                StalledSiblingApi16AnimeSource::class.java,
                "anime",
                "videos",
                apiVersion = "16",
                requestFields = mapOf("hosterLoadTimeoutMs" to 100),
            )
        } finally {
            StalledSiblingApi16AnimeSource.releaseStall()
        }
        val elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedAt)

        assertTrue(StalledSiblingApi16AnimeSource.stallStarted.await(1, TimeUnit.SECONDS))
        assertTrue("stalled sibling held the result for ${elapsedMs}ms", elapsedMs < 1_500)
        assertEquals(8, result.getJSONArray("videos").length())
        assertEquals(
            "https://media.example.test/fast-0.mp4",
            result.getJSONArray("videos").getJSONObject(0).getString("url"),
        )
        assertEquals(9, result.getInt("originalHosterCount"))
        assertEquals(9, result.getInt("visitedHosterCount"))
        assertEquals(1, result.getInt("discardedHosterCount"))
        assertEquals(0, result.getInt("deferredHosterCount"))
        assertTrue(StalledSiblingApi16AnimeSource.maxConcurrentLoads.get() <= 3)
        assertTrue(StalledSiblingApi16AnimeSource.maxConcurrentLoads.get() >= 2)
        assertTrue(StalledSiblingApi16AnimeSource.stallFinished.await(1, TimeUnit.SECONDS))
    }

    @Test fun api16MixedLazyFailureKeepsProviderRankAndExactHosterInvariants() {
        MixedLazyOrderingApi16AnimeSource.resetTestState()
        val result = execute(
            MixedLazyOrderingApi16AnimeSource::class.java,
            "anime",
            "videos",
            apiVersion = "16",
            requestFields = mapOf(
                "resolveLazyHosters" to true,
                "lazyHosterLimit" to 2,
                "hosterLoadTimeoutMs" to 500,
            ),
        )

        val videos = result.getJSONArray("videos")
        assertEquals(2, videos.length())
        assertEquals("https://media.example.test/lazy-ranked-first.mp4", videos.getJSONObject(0).getString("url"))
        assertEquals("https://media.example.test/eager-ranked-third.mp4", videos.getJSONObject(1).getString("url"))
        // Eager work is admitted first, but three IO jobs may enter provider
        // code in either order. Assert exact multiplicity, not thread timing;
        // the returned-video assertions above still require provider rank.
        assertEquals(
            listOf("eager-ranked-third", "lazy-failure", "lazy-ranked-first"),
            MixedLazyOrderingApi16AnimeSource.loadOrder.sorted(),
        )
        assertEquals(4, result.getInt("originalHosterCount"))
        assertEquals(4, result.getInt("visitedHosterCount"))
        assertEquals(0, result.getInt("truncatedHosterCount"))
        assertEquals(3, result.getInt("lazyHosterCount"))
        assertEquals(2, result.getInt("attemptedLazyHosterCount"))
        assertEquals(1, result.getInt("resolvedLazyHosterCount"))
        assertEquals(1, result.getInt("failedLazyHosterCount"))
        assertEquals(1, result.getInt("discardedHosterCount"))
        assertEquals(1, result.getInt("deferredHosterCount"))
        assertEquals(2, result.getInt("originalCount"))
        assertEquals(2, result.getInt("returnedCount"))
    }

    @Test fun api16ProviderOwnedLazyTimeoutDoesNotDiscardEagerSibling() {
        val result = execute(
            ProviderTimeoutWithSiblingApi16AnimeSource::class.java,
            "anime",
            "videos",
            apiVersion = "16",
            requestFields = mapOf(
                "resolveLazyHosters" to true,
                "lazyHosterLimit" to 1,
                "hosterLoadTimeoutMs" to 500,
            ),
        )

        val videos = result.getJSONArray("videos")
        assertEquals(1, videos.length())
        assertEquals("https://media.example.test/eager-survives.mp4", videos.getJSONObject(0).getString("url"))
        assertEquals(1, result.getInt("attemptedLazyHosterCount"))
        assertEquals(0, result.getInt("resolvedLazyHosterCount"))
        assertEquals(1, result.getInt("failedLazyHosterCount"))
        assertEquals(1, result.getInt("discardedHosterCount"))
        assertEquals(0, result.getInt("deferredHosterCount"))
    }

    @Test fun nativePlayerArgumentsFailClosed() {
        val failure = assertThrows(AniyomiRuntimeFailure::class.java) {
            execute(UnsafeVideoSource::class.java, "anime", "videos")
        }
        assertEquals("unsupported_capability", failure.category)
        assertEquals("source_videos", failure.stage)
    }

    @Test fun authenticatedRequestFailsBeforeBrokerAsUnsupportedCapability() {
        val failure = assertThrows(AniyomiRuntimeFailure::class.java) {
            execute(AuthenticatedMangaSource::class.java, "manga", "search") { error("Broker must not see credentials") }
        }
        assertEquals("unsupported_capability", failure.category)
    }

    @Test fun providerApplicationInterceptorsRunBeforeTheBrokerBoundary() {
        val result = execute(CustomInterceptorMangaSource::class.java, "manga", "search") { request ->
            assertEquals("fixture-client", request.getJSONObject("headers").getString("X-Provider-Client"))
            response("<a class='series' href='/series'>Fixture manga</a>", request)
        }
        assertEquals("Fixture manga", result.getJSONArray("items").getJSONObject(0).getString("title"))
    }

    @Test fun providerNetworkInterceptorsRemainUnsupported() {
        val failure = assertThrows(AniyomiRuntimeFailure::class.java) {
            execute(NetworkInterceptorMangaSource::class.java, "manga", "search") { error("Broker must not run") }
        }
        assertEquals("unsupported_capability", failure.category)
    }

    @Test fun unknownApiFailsBeforeLoadingClasses() {
        val descriptor = JSONObject().put("kind", "anime").put("apiVersion", "18")
            .put("classNames", JSONArray().put("does.not.Exist"))
        val failure = assertThrows(AniyomiRuntimeFailure::class.java) {
            AniyomiCompatRuntime.execute(javaClass.classLoader!!, descriptor, JSONObject().put("operation", "sources")) { error("No broker") }
        }
        assertEquals("runtime_setup", failure.stage)
        assertEquals("invalid_input", failure.category)
    }

    @Test fun oldDefaultImplsAndVideoConstructorRemainInRuntime() {
        assertNotNull(Class.forName("eu.kanade.tachiyomi.source.Source\$DefaultImpls"))
        assertNotNull(Class.forName("eu.kanade.tachiyomi.animesource.AnimeCatalogueSource\$DefaultImpls"))
        assertNotNull(Class.forName("eu.kanade.tachiyomi.animesource.model.Track"))
        assertNotNull(Track::class.java.getConstructor(String::class.java, String::class.java))
        assertNotNull(Video::class.java.getConstructor(String::class.java, String::class.java, String::class.java, okhttp3.Headers::class.java, List::class.java, List::class.java))
    }


    private fun response(html: String, request: JSONObject): JSONObject = JSONObject().put("statusCode", 200)
        .put("headers", JSONObject().put("Content-Type", "text/html"))
        .put("url", request.getString("url")).put("bodyBase64", Base64.getEncoder().encodeToString(html.toByteArray()))
}

/** First-party fixture reproducing the inspected KAA 14.61 request construction. */
class KickAssStyleSearchFixture : AnimeHttpSource() {
    override val name = "KickAss request compatibility fixture"
    override val lang = "en"
    override val baseUrl = "https://kaa.lt"
    override val supportsLatest = false

    override suspend fun getSearchAnime(page: Int, query: String, filters: AnimeFilterList): AnimesPage {
        val requestHeaders = headers.newBuilder()
            .add("Accept", "application/json, text/plain, */*")
            .add("Content-Type", "application/json")
            .add("Host", "kaa.lt")
            .add("Referer", "$baseUrl/search?q=$query")
            .build()
        val body = JSONObject().put("page", page).put("query", query).toString()
            .toRequestBody("application/json".toMediaType())
        return client.newCall(POST("$baseUrl/api/fsearch", requestHeaders, body)).awaitSuccess().use {
            AnimesPage(listOf(parseItem(it)), false)
        }
    }

    override suspend fun getAnimeDetails(anime: SAnime): SAnime =
        client.newCall(GET("$baseUrl/api/show/fixture")).awaitSuccess().use(::parseItem)

    override suspend fun getEpisodeList(anime: SAnime): List<SEpisode> =
        client.newCall(GET("$baseUrl/api/show/fixture/episodes")).awaitSuccess().use {
            listOf(SEpisode.create().apply { url = "/fixture/ep-1"; name = it.body.string(); episode_number = 1f })
        }

    @Suppress("DEPRECATION")
    override suspend fun getVideoList(episode: SEpisode): List<Video> =
        client.newCall(GET("$baseUrl/api/show/fixture/episode/ep-1")).awaitSuccess().use {
            listOf(Video(videoUrl = it.body.string(), videoTitle = "fixture", initialized = true))
        }

    private fun parseItem(response: Response): SAnime = SAnime.create().apply {
        url = "/fixture"
        title = JSONObject(response.body.string()).getString("title")
    }
}

class FixtureAnimeFactory : AnimeSourceFactory {
    override fun createSources(): List<AnimeSource> = listOf(FixtureAnimeSource())
}

open class FixtureAnimeSource : AnimeCatalogueSource {
    override val id = 42L
    override val name = "Built-in test fixture"
    override val lang = "en"
    override val supportsLatest = false
    override fun getFilterList() = AnimeFilterList()
    override suspend fun getSeasonList(anime: SAnime) = emptyList<SAnime>()
    private fun item() = SAnime.create().apply {
        url = "/series"; title = "Fixture anime"; description = "A generated test fixture"
    }
    override fun fetchSearchAnime(page: Int, query: String, filters: AnimeFilterList) = Observable.just(AnimesPage(listOf(item()), false))
    override fun fetchPopularAnime(page: Int) = fetchSearchAnime(page, "", getFilterList())
    override fun fetchLatestUpdates(page: Int) = fetchPopularAnime(page)
    override fun fetchAnimeDetails(anime: SAnime) = Observable.just(item())
    override fun fetchEpisodeList(anime: SAnime) = Observable.just(listOf(SEpisode.create().apply {
        url = "/episode"; name = "Episode 1"; episode_number = 1f
    }))
    override fun fetchVideoList(episode: SEpisode) = Observable.just(listOf(Video("https://fixture.example.test/watch", "720p", "https://media.example.test/fixture.mp4")))
}

class LongEpisodeAnimeSource : FixtureAnimeSource() {
    override fun fetchEpisodeList(anime: SAnime) = Observable.just(
        (1..5000).map { number ->
            SEpisode.create().apply {
                url = "/episode/$number"
                name = "Episode $number"
                episode_number = number.toFloat()
            }
        },
    )
}

class LabelOnlyLongEpisodeAnimeSource : FixtureAnimeSource() {
    override fun fetchEpisodeList(anime: SAnime) = Observable.just(
        (1..5000).map { number ->
            SEpisode.create().apply {
                url = "/episode/$number"
                name = "Season 1 Episode $number"
                episode_number = -1f
            }
        } + SEpisode.create().apply {
            url = "/season-2/episode-3500"
            name = "Season 2 Episode 3500"
            episode_number = -1f
        },
    )
}

class DuplicateEpisodeAnimeSource : FixtureAnimeSource() {
    override fun fetchEpisodeList(anime: SAnime) = Observable.just(
        List(80) { index ->
            SEpisode.create().apply {
                url = "/duplicate/$index"
                name = "Episode 12"
                episode_number = 12f
            }
        },
    )
}

open class SeasonContainerAnimeSource : FixtureAnimeSource() {
    override fun fetchAnimeDetails(anime: SAnime) = Observable.just(SAnime.create().apply {
        url = "/series/canonical"
        title = "Fixture anime"
        fetch_type = FetchType.Seasons
    })

    override suspend fun getSeasonList(anime: SAnime): List<SAnime> = (1..300).map { number ->
        SAnime.create().apply {
            url = "/series/season/$number"
            title = "Fixture anime Season $number"
            fetch_type = FetchType.Episodes
            season_number = number.toDouble()
        }
    }
}

class OversizedSeasonAnimeSource : SeasonContainerAnimeSource() {
    override suspend fun getSeasonList(anime: SAnime): List<SAnime> = (1..1001).map { number ->
        SAnime.create().apply {
            url = "/series/season/$number"
            title = "Fixture anime Season $number"
            fetch_type = FetchType.Episodes
            season_number = number.toDouble()
        }
    }
}

class MixedVideoAnimeSource : FixtureAnimeSource() {
    override fun fetchVideoList(episode: SEpisode) = Observable.just(
        listOf(
            Video(videoUrl = "http://private.invalid/video.mp4", videoTitle = "invalid scheme"),
            Video(
                videoUrl = "https://media.example.test/native.mp4",
                videoTitle = "native arguments",
                mpvArgs = listOf("script" to "/unsafe.lua"),
            ),
            Video(videoUrl = "https://media.example.test/valid.mp4", videoTitle = "valid"),
        ),
    )
}

class DuplicatePlaybackHeaderAnimeSource : FixtureAnimeSource() {
    override fun fetchVideoList(episode: SEpisode) = Observable.just(
        listOf(
            Video(
                videoUrl = "https://media.example.test/fixture.m3u8",
                videoTitle = "header fixture",
                headers = okhttp3.Headers.Builder()
                    .add("Referer", "https://embed.example.test/old")
                    .add("Referer", "https://embed.example.test/final")
                    .add("Origin", "https://old.example.test")
                    .add("Origin", "https://media.example.test")
                    .add("User-Agent", "old-agent")
                    .add("User-Agent", "final-agent")
                    .add("Accept", "video/*")
                    .add("Accept", "application/vnd.apple.mpegurl")
                    .add("Accept-Language", "en-US")
                    .add("Accept-Language", "ja-JP")
                    .add("Sec-Fetch-Dest", "empty")
                    .add("Sec-Fetch-Mode", "cors")
                    .add("Sec-Fetch-Site", "same-site")
                    .add("Cache-Control", "no-store")
                    .build(),
            ),
        ),
    )
}

class MixedTrackVideoAnimeSource : FixtureAnimeSource() {
    override fun fetchVideoList(episode: SEpisode) = Observable.just(
        listOf(
            Video(
                videoUrl = "https://media.example.test/with-tracks.mp4",
                videoTitle = "valid video",
                subtitleTracks = listOf(
                    Track("file:///data/user/0/dev.animetv/cache/decrypted.txt", "English"),
                    Track("https://media.example.test/spanish.vtt", "Spanish"),
                ),
                audioTracks = listOf(
                    Track("http://media.example.test/unsafe.aac", "English"),
                    Track("https://media.example.test/japanese.aac", "Japanese"),
                ),
            ),
        ),
    )
}

class LongVideoAnimeSource : FixtureAnimeSource() {
    override fun fetchVideoList(episode: SEpisode) = Observable.just(
        List(200) { index ->
            Video(
                videoUrl = "https://media.example.test/$index.mp4",
                videoTitle = "Server $index",
            )
        },
    )
}

class UnsafeVideoSource : FixtureAnimeSource() {
    override fun fetchVideoList(episode: SEpisode) = Observable.just(listOf(Video(
        videoUrl = "https://media.example.test/fixture.mp4", mpvArgs = listOf("script" to "/unsafe.lua"),
    )))
}

class PreferenceConstructingAnimeSource : FixtureAnimeSource() {
    private val preferences = Injekt.get<Application>().getSharedPreferences("source_42", Context.MODE_PRIVATE)
    private val constructionCount = preferences.getInt("construction_count", 0) + 1

    init {
        preferences.edit().putInt("construction_count", constructionCount).commit()
    }

    override val name = "Preference fixture $constructionCount"
}

class PrivilegedContextAnimeSource : FixtureAnimeSource() {
    @Suppress("unused")
    private val forbiddenPath = Injekt.get<Application>().filesDir.absolutePath
}

class JsonConstructingAnimeSource : FixtureAnimeSource() {
    private val json = Injekt.get<Json>()

    override fun fetchSearchAnime(page: Int, query: String, filters: AnimeFilterList) = Observable.just(
        AnimesPage(
            listOf(SAnime.create().apply {
                url = "/configured-json"
                title = json.parseToJsonElement("{\"title\":\"Configured JSON\"}")
                    .jsonObject.getValue("title").jsonPrimitive.content
            }),
            false,
        ),
    )
}

class FixtureApi16AnimeSource : AnimeSource {
    override val id = 160L
    override val name = "API 16 fixture"
    override suspend fun getSeasonList(anime: SAnime): List<SAnime> = emptyList()

    override suspend fun getHosterList(episode: SEpisode): List<Hoster> = listOf(
        Hoster(
            hosterUrl = "https://hoster.example.test/embedded",
            hosterName = "embedded",
            videoList = listOf(
                Video(
                    videoUrl = "https://media.example.test/embedded.mp4",
                    videoTitle = "embedded",
                    initialized = true,
                ),
            ),
        ),
        Hoster(
            hosterUrl = "https://hoster.example.test/deferred",
            hosterName = "deferred",
        ),
    )

    override suspend fun getVideoList(hoster: Hoster): List<Video> = listOf(
        Video(
            videoUrl = "https://media.example.test/deferred.mp4",
            videoTitle = "deferred",
            initialized = true,
        ),
    )
}

class AllLazyApi16AnimeSource : AnimeSource {
    override val id = 161L
    override val name = "All-lazy API 16 fixture"
    override suspend fun getSeasonList(anime: SAnime): List<SAnime> = emptyList()

    override suspend fun getHosterList(episode: SEpisode): List<Hoster> = listOf(
        Hoster(
            hosterUrl = "https://hoster.example.test/one",
            hosterName = "one",
            lazy = true,
        ),
        Hoster(
            hosterUrl = "https://hoster.example.test/two",
            hosterName = "two",
            lazy = true,
        ),
    )

    override suspend fun getVideoList(hoster: Hoster): List<Video> = listOf(
        Video(
            videoUrl = "https://media.example.test/lazy-${hoster.hosterName}.mp4",
            videoTitle = hoster.hosterName,
            initialized = true,
        ),
    )
}

class LazyFirstBudgetApi16AnimeSource : AnimeSource {
    override val id = 162L
    override val name = "Lazy-first budget fixture"
    override suspend fun getSeasonList(anime: SAnime): List<SAnime> = emptyList()

    override suspend fun getHosterList(episode: SEpisode): List<Hoster> = listOf(
        Hoster(
            hosterUrl = "https://hoster.example.test/lazy-first",
            hosterName = "lazy-first",
            lazy = true,
        ),
        Hoster(
            hosterUrl = "https://hoster.example.test/eager-after-lazy",
            hosterName = "eager-after-lazy",
        ),
    )

    override suspend fun getVideoList(hoster: Hoster): List<Video> = when (hoster.hosterName) {
        "eager-after-lazy" -> {
            eagerLoaded.set(true)
            listOf(
                Video(
                    videoUrl = "https://media.example.test/eager-after-lazy.mp4",
                    videoTitle = "eager success",
                    initialized = true,
                ),
            )
        }
        "lazy-first" -> {
            lazyObservedEagerLoaded.set(eagerLoaded.get())
            delay(5_000)
            emptyList()
        }
        else -> error("unexpected_hoster")
    }

    companion object {
        val eagerLoaded = AtomicBoolean()
        val lazyObservedEagerLoaded = AtomicBoolean()

        fun resetTestState() {
            eagerLoaded.set(false)
            lazyObservedEagerLoaded.set(false)
        }
    }
}

class StalledSiblingApi16AnimeSource : AnimeSource {
    override val id = 163L
    override val name = "Stalled sibling fixture"
    override suspend fun getSeasonList(anime: SAnime): List<SAnime> = emptyList()

    override suspend fun getHosterList(episode: SEpisode): List<Hoster> =
        listOf(Hoster(hosterUrl = "https://hoster.example.test/stalled", hosterName = "stalled")) +
            List(8) { index ->
                Hoster(
                    hosterUrl = "https://hoster.example.test/fast-$index",
                    hosterName = "fast-$index",
                )
            }

    override suspend fun getVideoList(hoster: Hoster): List<Video> {
        val active = activeLoads.incrementAndGet()
        maxConcurrentLoads.updateAndGet { previous -> maxOf(previous, active) }
        return try {
            if (hoster.hosterName == "stalled") {
                stallStarted.countDown()
                stallRelease.await()
                emptyList()
            } else {
                listOf(
                    Video(
                        videoUrl = "https://media.example.test/${hoster.hosterName}.mp4",
                        videoTitle = hoster.hosterName,
                        initialized = true,
                    ),
                )
            }
        } finally {
            activeLoads.decrementAndGet()
            if (hoster.hosterName == "stalled") stallFinished.countDown()
        }
    }

    companion object {
        @Volatile private var stallRelease = CountDownLatch(1)
        @Volatile var stallStarted = CountDownLatch(1)
            private set
        @Volatile var stallFinished = CountDownLatch(1)
            private set
        private val activeLoads = AtomicInteger()
        val maxConcurrentLoads = AtomicInteger()

        fun resetTestState() {
            stallRelease = CountDownLatch(1)
            stallStarted = CountDownLatch(1)
            stallFinished = CountDownLatch(1)
            activeLoads.set(0)
            maxConcurrentLoads.set(0)
        }

        fun releaseStall() {
            stallRelease.countDown()
        }
    }
}

class MixedLazyOrderingApi16AnimeSource : AnimeSource {
    override val id = 164L
    override val name = "Mixed lazy ordering fixture"
    override suspend fun getSeasonList(anime: SAnime): List<SAnime> = emptyList()

    override suspend fun getHosterList(episode: SEpisode): List<Hoster> = listOf(
        Hoster(hosterUrl = "https://hoster.example.test/lazy-ranked-first", hosterName = "lazy-ranked-first", lazy = true),
        Hoster(hosterUrl = "https://hoster.example.test/lazy-failure", hosterName = "lazy-failure", lazy = true),
        Hoster(hosterUrl = "https://hoster.example.test/eager-ranked-third", hosterName = "eager-ranked-third"),
        Hoster(hosterUrl = "https://hoster.example.test/lazy-deferred", hosterName = "lazy-deferred", lazy = true),
    )

    override suspend fun getVideoList(hoster: Hoster): List<Video> {
        loadOrder.add(hoster.hosterName)
        return when (hoster.hosterName) {
            "lazy-ranked-first" -> listOf(
                Video(
                    videoUrl = "https://media.example.test/lazy-ranked-first.mp4",
                    videoTitle = "lazy ranked first",
                    initialized = true,
                ),
            )
            "lazy-failure" -> error("fixture_lazy_failure")
            "eager-ranked-third" -> listOf(
                Video(
                    videoUrl = "https://media.example.test/eager-ranked-third.mp4",
                    videoTitle = "eager ranked third",
                    initialized = true,
                ),
            )
            else -> error("deferred_hoster_must_not_load")
        }
    }

    companion object {
        val loadOrder = CopyOnWriteArrayList<String>()

        fun resetTestState() {
            loadOrder.clear()
        }
    }
}

class ProviderTimeoutWithSiblingApi16AnimeSource : AnimeSource {
    override val id = 165L
    override val name = "Provider timeout with sibling fixture"
    override suspend fun getSeasonList(anime: SAnime): List<SAnime> = emptyList()

    override suspend fun getHosterList(episode: SEpisode): List<Hoster> = listOf(
        Hoster(hosterUrl = "https://hoster.example.test/eager", hosterName = "eager"),
        Hoster(
            hosterUrl = "https://hoster.example.test/provider-timeout",
            hosterName = "provider-timeout",
            lazy = true,
        ),
    )

    override suspend fun getVideoList(hoster: Hoster): List<Video> = when (hoster.hosterName) {
        "eager" -> listOf(
            Video(
                videoUrl = "https://media.example.test/eager-survives.mp4",
                videoTitle = "eager survives",
                initialized = true,
            ),
        )
        "provider-timeout" -> withTimeout(10) {
            delay(1_000)
            emptyList()
        }
        else -> error("unexpected_hoster")
    }
}

open class TransitionalApi16AnimeHttpSource : AnimeHttpSource() {
    override val name = "API 16 transitional fixture"
    override val lang = "en"
    override val supportsLatest = false
    override val baseUrl = "https://fixture.example.test"
    override suspend fun getSeasonList(anime: SAnime): List<SAnime> = emptyList()

    @Suppress("DEPRECATION")
    override suspend fun getVideoList(episode: SEpisode): List<Video> = listOf(
        Video(
            videoUrl = "https://media.example.test/fixture.mp4",
            videoTitle = "transitional",
        ),
    )
}

class RelativeArtworkAnimeHttpSource : TransitionalApi16AnimeHttpSource() {
    override fun fetchSearchAnime(page: Int, query: String, filters: AnimeFilterList) = Observable.just(
        AnimesPage(
            listOf(
                SAnime.create().apply {
                    url = "/relative"
                    title = "Relative artwork"
                    thumbnail_url = "/images/relative.jpg"
                },
                SAnime.create().apply {
                    url = "/scheme-relative"
                    title = "Scheme-relative artwork"
                    thumbnail_url = "//cdn.example.test/scheme-relative.jpg"
                },
                SAnime.create().apply {
                    url = "/unsafe"
                    title = "Unsafe artwork"
                    thumbnail_url = "http://images.example.test/unsafe.jpg"
                },
            ),
            false,
        ),
    )
}

class SortedLegacyVideoAnimeSource : TransitionalApi16AnimeHttpSource() {
    @Suppress("DEPRECATION")
    override suspend fun getVideoList(episode: SEpisode): List<Video> = listOf(
        Video(videoUrl = "https://media.example.test/fallback.mp4", videoTitle = "fallback"),
        Video(videoUrl = "https://media.example.test/preferred.mp4", videoTitle = "preferred"),
    )

    override fun List<Video>.sortVideos(): List<Video> = sortedByDescending { it.videoTitle }
}

class ResilientApi16AnimeHttpSource : AnimeHttpSource() {
    override val name = "API 16 resilient fixture"
    override val lang = "en"
    override val supportsLatest = false
    override val baseUrl = "https://fixture.example.test"
    override suspend fun getSeasonList(anime: SAnime): List<SAnime> = emptyList()

    override suspend fun getHosterList(episode: SEpisode): List<Hoster> = listOf(
        Hoster(hosterUrl = "$baseUrl/failure", hosterName = "failure"),
        Hoster(hosterUrl = "$baseUrl/success", hosterName = "success"),
        Hoster(hosterUrl = "$baseUrl/lazy", hosterName = "lazy", lazy = true),
        Hoster(
            hosterUrl = "$baseUrl/mixed",
            hosterName = "mixed",
            videoList = listOf(
                Video(
                    videoUrl = "https://media.example.test/mixed-bad.mp4",
                    videoTitle = "bad resolution",
                    initialized = false,
                ),
                Video(
                    videoUrl = "https://media.example.test/mixed-good.mp4",
                    videoTitle = "mixed good",
                    initialized = true,
                ),
            ),
        ),
    )

    override suspend fun getVideoList(hoster: Hoster): List<Video> {
        if (hoster.hosterName == "lazy") lazyLoads.incrementAndGet()
        val now = activeLoads.incrementAndGet()
        maxConcurrentLoads.updateAndGet { previous -> maxOf(previous, now) }
        loadGate.countDown()
        check(loadGate.await(2, TimeUnit.SECONDS)) { "parallel_hoster_load_expected" }
        return try {
            when (hoster.hosterName) {
                "failure" -> error("provider-secret-hoster-failure")
                "success" -> listOf(
                    Video(
                        videoUrl = "https://media.example.test/success.mp4",
                        videoTitle = "success",
                        initialized = true,
                    ),
                )
                else -> error("unexpected_hoster_load")
            }
        } finally {
            activeLoads.decrementAndGet()
        }
    }

    override suspend fun resolveVideo(video: Video): Video? {
        if (video.videoTitle == "bad resolution") error("provider-secret-video-failure")
        return video.copy(initialized = true)
    }

    companion object {
        private val activeLoads = AtomicInteger()
        val maxConcurrentLoads = AtomicInteger()
        val lazyLoads = AtomicInteger()
        @Volatile private var loadGate = CountDownLatch(2)

        fun resetTestState() {
            activeLoads.set(0)
            maxConcurrentLoads.set(0)
            lazyLoads.set(0)
            loadGate = CountDownLatch(2)
        }
    }
}

open class FixtureMangaSource : ParsedHttpSource() {
    override val name = "Generated manga fixture"
    override val lang = "en"
    override val supportsLatest = false
    override val baseUrl = "https://fixture.example.test"
    override fun popularMangaRequest(page: Int) = GET("$baseUrl/search", headers)
    override fun searchMangaRequest(page: Int, query: String, filters: FilterList) = popularMangaRequest(page)
    override fun latestUpdatesRequest(page: Int) = popularMangaRequest(page)
    override fun popularMangaSelector() = "a.series"
    override fun searchMangaSelector() = popularMangaSelector()
    override fun latestUpdatesSelector() = popularMangaSelector()
    override fun popularMangaNextPageSelector() = "a.next"
    override fun searchMangaNextPageSelector() = popularMangaNextPageSelector()
    override fun latestUpdatesNextPageSelector() = popularMangaNextPageSelector()
    override fun popularMangaFromElement(element: Element) = SManga.create().apply { url = element.attr("href"); title = element.text() }
    override fun searchMangaFromElement(element: Element) = popularMangaFromElement(element)
    override fun latestUpdatesFromElement(element: Element) = popularMangaFromElement(element)
    override fun mangaDetailsParse(document: Document) = SManga.create().apply { title = document.select("h1").text(); description = document.select("p").text() }
    override fun chapterListSelector() = "a.chapter"
    override fun chapterFromElement(element: Element) = SChapter.create().apply { url = element.attr("href"); name = element.text(); chapter_number = 1f }
    override fun chapterPageParse(response: Response) = SChapter.create()
    override fun pageListParse(document: Document) = document.select("img").mapIndexed { index, element -> Page(index, imageUrl = element.attr("src")) }
    override fun imageUrlParse(document: Document) = document.select("img").attr("src")
}

class DeferredImageMangaSource : FixtureMangaSource() {
    override fun pageListParse(document: Document): List<Page> =
        listOf(Page(index = 0, url = "$baseUrl/image-token"))

    override fun imageRequest(page: Page): Request = GET(
        page.imageUrl!!,
        okhttp3.Headers.Builder()
            .add("Referer", "$baseUrl/reader")
            .add("Authorization", "Bearer image-token")
            .add("Cookie", "image_session=private")
            .add("X-Ignored-Image-Control", "must-not-cross")
            .build(),
    )
}

class NoisyCoverHeaderMangaSource : FixtureMangaSource() {
    override fun headersBuilder() = super.headersBuilder().add("X-Provider-Noise", "drop-at-image-boundary")

    override fun popularMangaFromElement(element: Element) = super.popularMangaFromElement(element).apply {
        thumbnail_url = "https://images.example.test/cover.jpg"
    }
}

class AuthenticatedMangaSource : FixtureMangaSource() {
    override fun headersBuilder() = super.headersBuilder().add("Authorization", "Bearer generated-test-token")
}

class CustomInterceptorMangaSource : FixtureMangaSource() {
    override val client get() = super.client.newBuilder().addInterceptor { chain ->
        chain.proceed(chain.request().newBuilder().header("X-Provider-Client", "fixture-client").build())
    }.build()
}

class NetworkInterceptorMangaSource : FixtureMangaSource() {
    override val client get() = super.client.newBuilder().addNetworkInterceptor { it.proceed(it.request()) }.build()
}
