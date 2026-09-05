package dev.animetv.anime_tv.player

import org.junit.Assert.*
import org.junit.Test

class Media3BridgePolicyTest {
    @Test fun mergedSidecarIdsPreserveBatchIdentityButNeverAliasEmbeddedTracks() {
        val ids = listOf("sidecar:1", "sidecar:2", "sidecar:5")
        assertEquals("sidecar:1", Media3BridgePolicy.sidecarTrackId("1:sidecar:1", ids))
        assertEquals("sidecar:2", Media3BridgePolicy.sidecarTrackId("2:sidecar:2", ids))
        // A failed addition can leave a gap in public IDs; child index is the
        // accepted list position, not the numeric suffix of the public ID.
        assertEquals("sidecar:5", Media3BridgePolicy.sidecarTrackId("3:sidecar:5", ids))
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

    @Test fun codecLabelsAreClosedAndUnknownRemainsAbsent() {
        assertEquals("hevc", Media3BridgePolicy.codec("video/hevc"))
        assertEquals("aac", Media3BridgePolicy.codec("audio/mp4a-latm"))
        assertNull(Media3BridgePolicy.codec("private/movie.title"))
        assertNull(Media3BridgePolicy.codec(null))
    }
}
