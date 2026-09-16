package dev.animetv.anime_tv.aniyomi

import org.junit.Assert.*
import org.junit.Test

class AniyomiResultPolicyTest {
    @Test fun `video boundary drops all arbitrary native player and intent options`() {
        val result = AniyomiResultPolicy.sanitize("videos", mapOf("videos" to listOf(mapOf(
            "url" to "https://example.com/video.mp4", "quality" to "720p",
            "headers" to mapOf("Referer" to "https://example.com/"),
            "mpvArgs" to listOf("--script=/private/path"), "ffmpegArgs" to listOf("file:///data/private"),
            "intent" to "intent://launch", "subtitleTracks" to emptyList<Any>(), "audioTracks" to emptyList<Any>(),
        ))))
        val row = (result["videos"] as List<*>).single() as Map<*, *>
        assertEquals(setOf("url", "quality", "headers", "subtitleTracks", "audioTracks"), row.keys)
    }

    @Test fun `credential headers and private media URLs fail closed`() {
        for (url in listOf("file:///data/private", "http://example.com/video", "https://127.0.0.1/video")) {
            rejects { AniyomiResultPolicy.sanitize("pages", mapOf("pages" to listOf(mapOf("url" to url)))) }
        }
        for (header in listOf("Authorization", "Cookie", "Host", "Proxy-Authorization")) {
            rejects { AniyomiResultPolicy.sanitize("pages", mapOf("pages" to listOf(mapOf(
                "url" to "https://example.com/image.jpg", "headers" to mapOf(header to "secret"),
            )))) }
        }
    }

    @Test fun `bounded fetch metadata playback headers cross the host boundary`() {
        val result = AniyomiResultPolicy.sanitize("videos", mapOf("videos" to listOf(mapOf(
            "url" to "https://example.com/video.m3u8",
            "quality" to "1080p",
            "headers" to mapOf(
                "Sec-Fetch-Dest" to "empty",
                "Sec-Fetch-Mode" to "cors",
                "Sec-Fetch-Site" to "same-site",
            ),
            "subtitleTracks" to emptyList<Any>(),
            "audioTracks" to emptyList<Any>(),
        ))))
        val row = (result["videos"] as List<*>).single() as Map<*, *>
        assertEquals(
            mapOf(
                "Sec-Fetch-Dest" to "empty",
                "Sec-Fetch-Mode" to "cors",
                "Sec-Fetch-Site" to "same-site",
            ),
            row["headers"],
        )

        for ((name, value) in listOf(
            "Sec-Fetch-Dest" to "document",
            "Sec-Fetch-Mode" to "websocket",
            "Sec-Fetch-Site" to "provider-secret",
        )) {
            rejects {
                AniyomiResultPolicy.sanitize("videos", mapOf("videos" to listOf(mapOf(
                    "url" to "https://example.com/video.m3u8",
                    "quality" to "1080p",
                    "headers" to mapOf(name to value),
                    "subtitleTracks" to emptyList<Any>(),
                    "audioTracks" to emptyList<Any>(),
                ))))
            }
        }
    }

    @Test fun `source IDs preserve signed 64 bit precision without JSON number truncation`() {
        val result = AniyomiResultPolicy.sanitize("sources", mapOf("sources" to listOf(mapOf(
            "id" to "9223372036854775807", "name" to "Fixture", "lang" to "en", "kind" to "manga",
            "baseUrl" to "https://example.com", "supportsLatest" to false,
        ))))
        assertEquals("9223372036854775807", ((result["sources"] as List<*>).single() as Map<*, *>)["id"])
    }

    @Test fun `invalid optional artwork does not discard a valid catalog item`() {
        val result = AniyomiResultPolicy.sanitize("search", mapOf(
            "items" to listOf(mapOf(
                "url" to "/series/fixture",
                "title" to "Fixture anime",
                "thumbnailUrl" to "https://images.example.com:8161/cover.jpg",
            )),
            "hasNextPage" to false,
            "originalCount" to 1,
            "returnedCount" to 1,
            "truncatedCount" to 0,
        ))

        val item = (result["items"] as List<*>).single() as Map<*, *>
        assertEquals("/series/fixture", item["url"])
        assertEquals("Fixture anime", item["title"])
        assertNull(item["thumbnailUrl"])
    }

    @Test fun `lists and non finite numbers cannot cross host boundary`() {
        rejects { AniyomiResultPolicy.sanitize("search", mapOf("items" to List(101) { emptyMap<String, Any>() })) }
        rejects { AniyomiResultPolicy.sanitize("chapters", mapOf("chapters" to listOf(mapOf(
            "url" to "/chapter", "name" to "one", "number" to Double.NaN,
        )))) }
    }

    @Test fun `targeted episode count contract preserves bounded truncation diagnostics`() {
        val row = mapOf("url" to "/episode/12", "name" to "Episode 12", "number" to 12.0)
        val result = AniyomiResultPolicy.sanitize("episodes", mapOf(
            "chapters" to List(64) { row + ("url" to "/episode/12/$it") },
            "originalCount" to 5000,
            "returnedCount" to 64,
            "filteredCount" to 4900,
            "truncatedCount" to 36,
        ))
        assertEquals(5000, result["originalCount"])
        assertEquals(36, result["truncatedCount"])
        rejects { AniyomiResultPolicy.sanitize("episodes", mapOf(
            "chapters" to listOf(row),
            "originalCount" to 10,
            "returnedCount" to 1,
            "filteredCount" to 8,
            "truncatedCount" to 0,
        )) }
    }

    @Test fun `season rows preserve only bounded identity fields and exact count arithmetic`() {
        val row = mapOf(
            "url" to "/show/season-2",
            "title" to "Fixture Season 2",
            "fetchType" to "episodes",
            "seasonNumber" to 2.0,
            "privateMemo" to "must-not-cross",
        )
        val result = AniyomiResultPolicy.sanitize("seasons", mapOf(
            "seasons" to listOf(row),
            "originalCount" to 3,
            "returnedCount" to 1,
            "filteredCount" to 2,
            "truncatedCount" to 0,
        ))
        val season = (result["seasons"] as List<*>).single() as Map<*, *>
        assertEquals("episodes", season["fetchType"])
        assertEquals(2.0, season["seasonNumber"])
        assertFalse(season.containsKey("privateMemo"))

        rejects { AniyomiResultPolicy.sanitize("seasons", mapOf(
            "seasons" to List(17) { row },
            "originalCount" to 17,
            "returnedCount" to 17,
            "filteredCount" to 0,
            "truncatedCount" to 0,
        )) }
        rejects { AniyomiResultPolicy.sanitize("seasons", mapOf(
            "seasons" to listOf(row),
            "originalCount" to 3,
            "returnedCount" to 1,
            "filteredCount" to 1,
            "truncatedCount" to 0,
        )) }
        rejects { AniyomiResultPolicy.sanitize("details", mapOf(
            "item" to row + ("seasonNumber" to 2.5),
        )) }
    }

    @Test fun `successful broker context and list counts stay fixed and privacy safe`() {
        val result = AniyomiResultPolicy.sanitize("search", mapOf(
            "items" to emptyList<Any>(),
            "hasNextPage" to false,
            "originalCount" to 0,
            "returnedCount" to 0,
            "truncatedCount" to 0,
            "broker_redirect_count" to 2,
            "broker_response_size_bucket" to "64to128k",
            "broker_status_class" to "5xx",
            "url" to "https://must-not-cross.example/private",
        ))
        assertEquals(2, result["broker_redirect_count"])
        assertEquals("64to128k", result["broker_response_size_bucket"])
        assertEquals("5xx", result["broker_status_class"])
        assertFalse(result.containsKey("url"))

        rejects { AniyomiResultPolicy.sanitize("search", mapOf(
            "items" to emptyList<Any>(),
            "broker_redirect_count" to 0,
            "broker_response_size_bucket" to "exact-byte-count",
            "broker_status_class" to "503",
        )) }
    }

    @Test fun `video counts accept salvaged rows and reject inconsistent arithmetic`() {
        val video = mapOf(
            "url" to "https://example.com/video.mp4",
            "quality" to "720p",
            "headers" to emptyMap<String, String>(),
            "subtitleTracks" to emptyList<Any>(),
            "audioTracks" to emptyList<Any>(),
        )
        val result = AniyomiResultPolicy.sanitize("videos", mapOf(
            "videos" to listOf(video),
            "originalCount" to 4,
            "returnedCount" to 1,
            "discardedVideoCount" to 2,
            "truncatedCount" to 1,
            "truncatedHosterCount" to 3,
            "discardedHosterCount" to 2,
            "deferredHosterCount" to 1,
            "originalHosterCount" to 7,
            "visitedHosterCount" to 4,
            "lazyHosterCount" to 3,
            "attemptedLazyHosterCount" to 2,
            "resolvedLazyHosterCount" to 1,
            "failedLazyHosterCount" to 1,
        ))
        assertEquals(2, result["discardedVideoCount"])
        assertEquals(1, result["truncatedCount"])
        assertEquals(3, result["truncatedHosterCount"])
        assertEquals(2, result["discardedHosterCount"])
        assertEquals(1, result["deferredHosterCount"])
        assertEquals(7, result["originalHosterCount"])
        assertEquals(4, result["visitedHosterCount"])
        assertEquals(3, result["lazyHosterCount"])
        assertEquals(2, result["attemptedLazyHosterCount"])
        assertEquals(1, result["resolvedLazyHosterCount"])
        assertEquals(1, result["failedLazyHosterCount"])
        rejects { AniyomiResultPolicy.sanitize("videos", mapOf(
            "videos" to listOf(video),
            "originalCount" to 3,
            "returnedCount" to 1,
            "discardedVideoCount" to 0,
            "truncatedCount" to 0,
        )) }
        rejects { AniyomiResultPolicy.sanitize("videos", mapOf(
            "videos" to listOf(video),
            "originalHosterCount" to 2,
            "visitedHosterCount" to 1,
            "truncatedHosterCount" to 0,
            "lazyHosterCount" to 1,
            "attemptedLazyHosterCount" to 1,
            "resolvedLazyHosterCount" to 1,
            "failedLazyHosterCount" to 1,
        )) }
    }

    @Test fun `bounded aggregate video counts above one hundred thousand preserve playable rows`() {
        val video = mapOf(
            "url" to "https://example.com/video.mp4",
            "quality" to "720p",
            "headers" to emptyMap<String, String>(),
            "subtitleTracks" to emptyList<Any>(),
            "audioTracks" to emptyList<Any>(),
        )
        val maximum = dev.animetv.anime_tv.aniyomi.compat.AniyomiCompatRuntime.MAX_AGGREGATE_VIDEOS
        val result = AniyomiResultPolicy.sanitize("videos", mapOf(
            "videos" to listOf(video),
            "originalCount" to maximum,
            "returnedCount" to 1,
            "discardedVideoCount" to 0,
            "truncatedCount" to maximum - 1,
        ))

        assertEquals(maximum, result["originalCount"])
        assertEquals(maximum - 1, result["truncatedCount"])
        assertEquals(1, (result["videos"] as List<*>).size)
    }

    @Test fun `unsafe individual tracks are dropped without discarding the video`() {
        val result = AniyomiResultPolicy.sanitize("videos", mapOf(
            "videos" to listOf(mapOf(
                "url" to "https://example.com/video.mp4",
                "quality" to "720p",
                "headers" to emptyMap<String, String>(),
                "subtitleTracks" to listOf(
                    mapOf("url" to "file:///data/private/subtitle.txt", "lang" to "English"),
                    mapOf("url" to "https://example.com/subtitle.vtt", "lang" to "Spanish"),
                ),
                "audioTracks" to listOf(
                    mapOf("url" to "https://127.0.0.1/private.aac", "lang" to "English"),
                    mapOf("url" to "https://example.com/audio.aac", "lang" to "Japanese"),
                ),
            )),
            "discardedTrackCount" to 2,
            "localHlsBridgeCount" to 1,
        ))

        val video = (result["videos"] as List<*>).single() as Map<*, *>
        val subtitles = video["subtitleTracks"] as List<*>
        val audio = video["audioTracks"] as List<*>
        assertEquals(1, subtitles.size)
        assertEquals("https://example.com/subtitle.vtt", (subtitles.single() as Map<*, *>)["url"])
        assertEquals(1, audio.size)
        assertEquals("https://example.com/audio.aac", (audio.single() as Map<*, *>)["url"])
        assertEquals(2, result["discardedTrackCount"])
        assertEquals(1, result["localHlsBridgeCount"])
        assertFalse(result.toString().contains("file:///"))
        assertFalse(result.toString().contains("127.0.0.1"))
    }

    @Test fun `manga page order is preserved with safe contiguous indexes`() {
        val result = AniyomiResultPolicy.sanitize("pages", mapOf(
            "pages" to listOf(
                mapOf("index" to 99, "url" to "https://example.com/second.jpg"),
                mapOf("index" to -4, "url" to "https://example.com/first.jpg"),
            ),
            "originalCount" to 2,
            "returnedCount" to 2,
            "truncatedCount" to 0,
        ))
        val pages = result["pages"] as List<*>
        assertEquals("https://example.com/second.jpg", (pages[0] as Map<*, *>)["url"])
        assertEquals(0, (pages[0] as Map<*, *>)["index"])
        assertEquals("https://example.com/first.jpg", (pages[1] as Map<*, *>)["url"])
        assertEquals(1, (pages[1] as Map<*, *>)["index"])
    }

    private fun rejects(block: () -> Unit) {
        try { block(); fail("Expected rejection") } catch (_: IllegalArgumentException) {} catch (_: IllegalStateException) {}
    }
}
