package dev.animetv.anime_tv.player

import java.io.File
import org.junit.Assert.*
import org.junit.Test

class Media3BridgePolicyTest {
    @Test fun hlsMimeAliasesSelectTheSameMedia3Source() {
        for (mime in listOf("application/vnd.apple.mpegurl", "application/x-mpegURL",
            "APPLICATION/VND.APPLE.MPEGURL; charset=utf-8", " application/x-mpegurl ")) {
            assertEquals(androidx.media3.common.MimeTypes.APPLICATION_M3U8, Media3BridgePolicy.playbackMime(mime))
            assertEquals(androidx.media3.common.MimeTypes.APPLICATION_M3U8, Media3BridgePolicy.normalizedExternalAudioMime(mime))
        }
        assertNull(Media3BridgePolicy.playbackMime(null))
        assertEquals("video/mp4", Media3BridgePolicy.playbackMime("video/mp4; charset=binary"))
        for (invalid in listOf("", "text/html", "application/javascript", "video/mp4\r\nX: invalid")) {
            assertThrows(IllegalArgumentException::class.java) { Media3BridgePolicy.playbackMime(invalid) }
        }
    }

    @Test fun nativeFailureClassificationsNeverCopyExceptionMessages() {
        val privateMessage = "https://private.example/token?secret=value"
        assertEquals("illegal_state", Media3BridgePolicy.exceptionKind(IllegalStateException(privateMessage)))
        assertEquals("concurrent_modification", Media3BridgePolicy.exceptionKind(java.util.ConcurrentModificationException(privateMessage)))
        assertEquals("other", Media3BridgePolicy.exceptionKind(Exception(privateMessage)))
    }
    @Test
    fun `release poll requires the owned playback thread to terminate`() {
        assertEquals(
            Media3ReleasePollAction.WAIT,
            media3ReleasePollAction(playbackThreadAlive = true, elapsedMs = 0),
        )
        assertEquals(
            Media3ReleasePollAction.WAIT,
            media3ReleasePollAction(
                playbackThreadAlive = true,
                elapsedMs = Media3BridgePolicy.RELEASE_COMPLETION_GRACE_MS - 1,
            ),
        )
        assertEquals(
            Media3ReleasePollAction.TIMED_OUT,
            media3ReleasePollAction(
                playbackThreadAlive = true,
                elapsedMs = Media3BridgePolicy.RELEASE_COMPLETION_GRACE_MS,
            ),
        )
        assertEquals(
            Media3ReleasePollAction.COMPLETE,
            media3ReleasePollAction(
                playbackThreadAlive = false,
                elapsedMs = Media3BridgePolicy.RELEASE_COMPLETION_GRACE_MS,
            ),
        )
    }

    @Test
    fun `process registry clears only playback threads proven dead`() {
        val alive = mutableMapOf("first" to true, "second" to true)
        val registry = Media3PlaybackThreadRegistry<String> { alive[it] == true }
        registry.track("first")
        registry.track("second")
        assertFalse(registry.allReleased())
        alive["first"] = false
        assertFalse(registry.allReleased())
        alive["second"] = false
        assertTrue(registry.allReleased())
    }

    @Test
    fun `release timeout and asynchronous proof stay within four seconds`() {
        assertEquals(1_000L, Media3BridgePolicy.RELEASE_TIMEOUT_MS)
        assertEquals(3_000L, Media3BridgePolicy.RELEASE_COMPLETION_GRACE_MS)
        assertEquals(4_000L, Media3BridgePolicy.RELEASE_TOTAL_TIMEOUT_MS)
        assertEquals(50L, Media3BridgePolicy.RELEASE_POLL_INTERVAL_MS)
    }

    @Test
    fun `timed out releases get bounded automatic reaping and a create-time sweep`() {
        assertEquals(30_000L, Media3BridgePolicy.RELEASE_AUTOMATIC_REAP_WINDOW_MS)
        assertEquals(250L, Media3BridgePolicy.RELEASE_AUTOMATIC_REAP_INTERVAL_MS)
        assertEquals(
            Media3ReleaseReapAction.REAP,
            media3ReleaseReapAction(playbackThreadAlive = false, elapsedMs = 0),
        )
        assertEquals(
            Media3ReleaseReapAction.WAIT,
            media3ReleaseReapAction(
                playbackThreadAlive = true,
                elapsedMs = Media3BridgePolicy.RELEASE_AUTOMATIC_REAP_WINDOW_MS - 1,
            ),
        )
        assertEquals(
            Media3ReleaseReapAction.STOP,
            media3ReleaseReapAction(
                playbackThreadAlive = true,
                elapsedMs = Media3BridgePolicy.RELEASE_AUTOMATIC_REAP_WINDOW_MS,
            ),
        )

        val source = media3BridgeSource()
        val create = source.substringAfter("if (call.method == \"create\")", "")
            .substringBefore("return", "")
        val sweepIndex = create.indexOf("reapCompletedSessions()")
        val registryIndex = create.indexOf("Media3ProcessReleaseSafety.allReleased()")
        val limitIndex = create.indexOf("sessions.size < Media3BridgePolicy.MAX_PLAYERS")
        assertTrue(sweepIndex >= 0)
        assertTrue(registryIndex > sweepIndex)
        assertTrue(limitIndex > registryIndex)
        val timedOut = source.substringAfter("Media3ReleasePollAction.TIMED_OUT ->", "")
            .substringBefore("private fun scheduleAutomaticReleaseReap", "")
        assertTrue(timedOut.contains("scheduleAutomaticReleaseReap(id, session)"))
        assertTrue(source.contains("session.releaseCanBeReaped"))
    }

    @Test
    fun `bridge keeps the default per-player playback looper ownership invariant`() {
        val source = media3BridgeSource()
        assertTrue(source.contains("old.playbackLooper.thread"))
        assertTrue(source.contains("default per-player owned"))
        assertFalse(source.contains(".setPlaybackLooperProvider("))
        assertFalse(source.contains(".setPlaybackLooper("))
        assertEquals(1, Regex("old\\.release\\(\\)").findAll(source).count())
    }

    @Test
    fun `bridge close completes pending Flutter release replies before clearing callbacks`() {
        val close = media3BridgeSource()
            .substringAfter("fun close()", "")
            .substringBefore("\n    }\n}", "")
        val replyIndex = close.indexOf("interruptedReleases.forEach")
        val clearCallbacksIndex = close.indexOf("handler.removeCallbacksAndMessages(null)")
        assertTrue(replyIndex >= 0)
        assertTrue(clearCallbacksIndex > replyIndex)
        assertTrue(close.contains("media3_closed"))
    }

    @Test fun mergedSidecarIdsPreserveBatchIdentityButNeverAliasEmbeddedTracks() {
        val ids = listOf("sidecar:1", "sidecar:2", "sidecar:5")
        assertEquals("sidecar:1", Media3BridgePolicy.sidecarTrackId("1:sidecar:1", ids))
        assertEquals("sidecar:2", Media3BridgePolicy.sidecarTrackId("2:sidecar:2", ids))
        // A failed addition can leave a gap in public IDs; child index is the
        // accepted list position, not the numeric suffix of the public ID.
        assertEquals("sidecar:5", Media3BridgePolicy.sidecarTrackId("3:sidecar:5", ids))
        assertEquals(
            "sidecar:1",
            Media3BridgePolicy.sidecarTrackId(
                "0:1:sidecar:1",
                ids,
                primaryWrappedForExternalAudio = true,
            ),
        )
        assertNull(
            Media3BridgePolicy.sidecarTrackId(
                "1:sidecar:1",
                ids,
                primaryWrappedForExternalAudio = true,
            ),
        )
        assertNull(Media3BridgePolicy.sidecarTrackId("0:1:sidecar:1", ids))
        for (raw in listOf(null, "sidecar:1", "0:sidecar:1", "1:sidecar:2", "2:sidecar:1", "0:1:sidecar:1", "01:sidecar:1", "1:sidecar:1:extra", "1:https://private.example")) {
            assertNull(Media3BridgePolicy.sidecarTrackId(raw, ids))
        }
        assertNull(Media3BridgePolicy.sidecarTrackId("1:sidecar:1", emptyList()))
    }

    @Test fun requestedEndBoundaryIsValidatedBeforeOpening() {
        assertNull(Media3BridgePolicy.endPositionMs(null, 17_000))
        assertEquals(20_000L, Media3BridgePolicy.endPositionMs(20_000, 17_000))
        assertEquals(604_800_000L, Media3BridgePolicy.endPositionMs(604_800_000L, 0))
        for (raw in listOf(0, -1, 16_000, 17_000, 20_000.5, Double.NaN, Double.POSITIVE_INFINITY, Long.MAX_VALUE, "20000")) {
            assertThrows(IllegalArgumentException::class.java) { Media3BridgePolicy.endPositionMs(raw, 17_000) }
        }
    }

    @Test fun chapterPositionsUseCurrentPeriodOffsetAndRejectUnknownOrOverflow() {
        assertEquals(5.0, Media3BridgePolicy.chapterPositionSeconds(10_000, -5_000))
        assertEquals(160.0, Media3BridgePolicy.chapterPositionSeconds(10_000, 150_000))
        assertNull(Media3BridgePolicy.chapterPositionSeconds(1_000, -5_000))
        assertNull(Media3BridgePolicy.chapterPositionSeconds(Long.MAX_VALUE, Long.MAX_VALUE))
        assertNull(Media3BridgePolicy.chapterPositionSeconds(Long.MIN_VALUE, 0))
    }

    @Test fun sidecarPayloadMimeSniffingSupportsOpaqueVttAssAndTtml() {
        assertEquals("text/vtt", Media3BridgePolicy.subtitleMime("\uFEFF WEBVTT\n\n".toByteArray()))
        assertEquals("text/x-ssa", Media3BridgePolicy.subtitleMime("\uFEFF[Script Info]\nTitle: Fixture\n[V4+ Styles]".toByteArray()))
        assertEquals("text/x-ssa", Media3BridgePolicy.subtitleMime("; intro\n[Events]\nDialogue: 0,0".toByteArray()))
        assertEquals("application/ttml+xml", Media3BridgePolicy.subtitleMime("<?xml version=\"1.0\"?>\n<tt xmlns=\"http://www.w3.org/ns/ttml\">".toByteArray()))
        assertEquals("application/x-subrip", Media3BridgePolicy.subtitleMime("1\n00:00:01,000 --> 00:00:02,000\nTest".toByteArray()))
        assertThrows(IllegalArgumentException::class.java) { Media3BridgePolicy.subtitleMime(byteArrayOf()) }
        assertThrows(IllegalArgumentException::class.java) { Media3BridgePolicy.subtitleMime(ByteArray(Media3BridgePolicy.MAX_SIDECAR_BYTES + 1)) }
    }

    @Test fun delayedCallbacksCannotEnterANewerOpenOrDecoderRestart() {
        val callbacks = Media3CallbackEpoch()
        val first = callbacks.begin(1)
        assertTrue(callbacks.accepts(first))
        val second = callbacks.begin(2)
        assertTrue(second.generation > first.generation)
        assertFalse(callbacks.accepts(first))
        assertTrue(callbacks.accepts(second))
        val decoderRestart = callbacks.begin(2)
        assertTrue(decoderRestart.generation > second.generation)
        assertEquals(second.openId, decoderRestart.openId)
        assertFalse(callbacks.accepts(second))
        assertTrue(callbacks.accepts(decoderRestart))
        callbacks.invalidate()
        assertFalse(callbacks.accepts(first))
        assertFalse(callbacks.accepts(second))
        assertFalse(callbacks.accepts(decoderRestart))
    }

    @Test fun supportedPlaybackUrisAreExplicitAndBounded() {
        for (uri in listOf("https://media.example/video.m3u8", "http://192.168.1.2:8080/video", "file:///storage/media/video.mkv", "content://provider/video/1")) {
            assertTrue(uri, Media3BridgePolicy.supportedUri(uri))
        }
        for (uri in listOf("javascript:alert(1)", "https://user:secret@example.test/video", "data:text/plain,secret", "file://remote/video", "/storage/video.mkv", "https://example.test/\nAuthorization: secret", "https://example.test/" + "x".repeat(16_384))) {
            assertFalse(uri.take(64), Media3BridgePolicy.supportedUri(uri))
        }
    }

    @Test fun authenticationStaysAtTheExactOriginalOrigin() {
        val source = "https://media.example/path?token=secret"
        assertTrue(Media3BridgePolicy.sameOrigin(source, "https://MEDIA.example:443/segment.ts"))
        for (target in listOf("http://media.example/segment.ts", "https://media.example:444/segment.ts", "https://sub.media.example/segment.ts", "https://other.example/subtitle.vtt", "https://media.example.evil.test/video", "file:///video", "https://user:secret@media.example/video")) {
            assertFalse(target, Media3BridgePolicy.sameOrigin(source, target))
        }
    }

    @Test fun callerHeadersDoNotAcceptInjectionOrTransportFraming() {
        assertEquals(mapOf("Authorization" to "Bearer secret", "Referer" to "https://media.example/"),
            Media3BridgePolicy.headers(mapOf("Authorization" to "Bearer secret", "Referer" to "https://media.example/")))
        for (headers in listOf(mapOf("Authorization" to "Bearer secret\r\nX-Leak: yes"), mapOf("Host" to "evil.example"), mapOf("Content-Length" to "100"), mapOf(" bad" to "x"), mapOf("X-Key" to "x".repeat(8193)))) {
            assertThrows(IllegalArgumentException::class.java) { Media3BridgePolicy.headers(headers) }
        }
        assertThrows(IllegalArgumentException::class.java) { Media3BridgePolicy.headers((0..64).associate { "X-$it" to "a" }) }
    }

    @Test fun finiteScalarValidationDoesNotCoerceMissingMetricsToZero() {
        for (raw in listOf(Double.NaN, Double.POSITIVE_INFINITY, "1", null, -1, 604_800_001, 1.25)) {
            assertNull(Media3BridgePolicy.integer(raw))
        }
        assertEquals(0L, Media3BridgePolicy.integer(0))
        assertEquals(250L, Media3BridgePolicy.integer(250.0))
        assertNull(Media3BridgePolicy.number(Double.NaN, 0.0, 4.0))
    }

    @Test fun unsupportedTimingOffsetsAreExplicitRatherThanIgnored() {
        assertEquals(emptyList<String>(), Media3BridgePolicy.unsupportedOptions(mapOf("audioDelayMs" to 0, "subtitleDelayMs" to 0.0, "fit" to "contain")))
        assertEquals(listOf("audioDelayMs", "subtitleDelayMs", "rawMpvOptions"), Media3BridgePolicy.unsupportedOptions(mapOf("audioDelayMs" to 100, "subtitleDelayMs" to -500, "rawMpvOptions" to "secret")))
    }

    @Test fun eventErrorsAndTrackIdsCannotEchoPrivateSources() {
        assertEquals("ERROR_CODE_IO_BAD_HTTP_STATUS", Media3BridgePolicy.errorCode("ERROR_CODE_IO_BAD_HTTP_STATUS"))
        for (raw in listOf("https://media.example/video?token=secret", "error: /storage/private/movie.mkv", "ERROR_CODE_BAD token")) {
            assertEquals("ERROR_CODE_UNSPECIFIED", Media3BridgePolicy.errorCode(raw))
            assertFalse(Media3BridgePolicy.validTrackId(raw))
        }
        assertTrue(Media3BridgePolicy.validTrackId("audio/g2/t1"))
        assertTrue(Media3BridgePolicy.validTrackId("sidecar:16"))
        assertEquals("c2.android.avc.decoder", Media3BridgePolicy.safeDecoderName("c2.android.avc.decoder"))
        assertNull(Media3BridgePolicy.safeDecoderName("https://private.example"))
    }

    @Test fun externalAudioAcceptsOnlyOwnedLoopbackResourcesAndBoundedMimes() {
        assertTrue(Media3BridgePolicy.ownedLoopbackAudioUri("http://127.0.0.1:49152/session/audio"))
        for (raw in listOf(
            "https://media.example/audio.aac",
            "http://localhost:49152/audio",
            "http://127.0.0.1/audio",
            "http://127.0.0.1:49152/",
            "http://user@127.0.0.1:49152/audio",
        )) {
            assertFalse(Media3BridgePolicy.ownedLoopbackAudioUri(raw))
        }
        assertEquals("audio/aac", Media3BridgePolicy.externalAudioMime("audio/aac; charset=binary"))
        assertEquals("application/vnd.apple.mpegurl", Media3BridgePolicy.externalAudioMime("application/vnd.apple.mpegurl"))
        assertNull(Media3BridgePolicy.externalAudioMime("video/mp4"))
        assertNull(Media3BridgePolicy.externalAudioMime("text/html"))
    }

    @Test fun mergedAudioChildIdentityIsBoundedAndDeterministic() {
        assertEquals(0, Media3BridgePolicy.mergedChildIndex("0:primary"))
        assertEquals(3, Media3BridgePolicy.mergedChildIndex("3:audio-group"))
        assertNull(Media3BridgePolicy.mergedChildIndex("audio-group"))
        assertNull(Media3BridgePolicy.mergedChildIndex("123:oversized-index"))
        assertNull(Media3BridgePolicy.mergedChildIndex("1".repeat(257)))
    }

    @Test fun externalAudioFailureGetsOnePrimaryOnlySalvageAttempt() {
        assertTrue(Media3BridgePolicy.shouldRetryPrimaryWithoutExternalAudio(1, false))
        assertTrue(
            Media3BridgePolicy.shouldRetryPrimaryWithoutExternalAudio(
                Media3BridgePolicy.MAX_AUDIO_SIDECARS,
                false,
            ),
        )
        assertFalse(Media3BridgePolicy.shouldRetryPrimaryWithoutExternalAudio(0, false))
        assertFalse(Media3BridgePolicy.shouldRetryPrimaryWithoutExternalAudio(1, true))
        assertFalse(
            Media3BridgePolicy.shouldRetryPrimaryWithoutExternalAudio(
                Media3BridgePolicy.MAX_AUDIO_SIDECARS + 1,
                false,
            ),
        )

        val source = media3BridgeSource()
        assertTrue(source.contains("val fallback = open.copy(audioTracks = emptyList())"))
        assertTrue(source.contains("externalAudioFallbackApplied = true"))
        assertTrue(source.contains("FilteringMediaSource("))
        assertTrue(source.contains("C.TRACK_TYPE_AUDIO"))
        assertTrue(source.contains("MergingMediaSource(\n                true,\n                true,"))
    }

    @Test fun runtimeSubtitleRebuildPreservesExternalAudioMerge() {
        val source = media3BridgeSource()
        val createPlayer = source.substringAfter("private fun createPlayer(", "")
            .substringBefore("private fun buildMediaSource(", "")
        val addSubtitle = source.substringAfter("fun addSubtitle(", "")
            .substringBefore("private fun parseSidecar(", "")
        val sourceBuilder = source.substringAfter("private fun buildMediaSource(", "")
            .substringBefore("private fun mediaItem(", "")

        assertTrue(
            createPlayer.contains(
                "native.setMediaSource(buildMediaSource(open, mediaSourceFactory), startMs)",
            ),
        )
        assertTrue(
            addSubtitle.contains(
                "buildMediaSource(updated, sourceFactory)",
            ),
        )
        assertFalse(addSubtitle.contains("setMediaItem(mediaItem(updated)"))
        assertTrue(sourceBuilder.contains("FilteringMediaSource("))
        assertTrue(sourceBuilder.contains("MergingMediaSource("))
    }

    @Test fun codecLabelsAreClosedAndUnknownRemainsAbsent() {
        assertEquals("hevc", Media3BridgePolicy.codec("video/hevc"))
        assertEquals("aac", Media3BridgePolicy.codec("audio/mp4a-latm"))
        assertNull(Media3BridgePolicy.codec("private/movie.title"))
        assertNull(Media3BridgePolicy.codec(null))
    }

    private fun media3BridgeSource(): String {
        val workingDirectory = System.getProperty("user.dir") ?: "."
        return generateSequence(File(workingDirectory)) { it.parentFile }
            .take(7)
            .flatMap { directory ->
                sequenceOf(
                    File(directory, "src/main/kotlin/dev/animetv/anime_tv/player/Media3FlutterBridge.kt"),
                    File(directory, "app/src/main/kotlin/dev/animetv/anime_tv/player/Media3FlutterBridge.kt"),
                    File(directory, "android/app/src/main/kotlin/dev/animetv/anime_tv/player/Media3FlutterBridge.kt"),
                )
            }
            .firstOrNull(File::isFile)
            ?.readText()
            ?: error("Missing Media3FlutterBridge.kt")
    }
}
