package dev.animetv.anime_tv

import android.app.ApplicationExitInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AnonymousCrashStoreTest {
    @Test
    fun `only crash and ANR exit reasons are reportable`() {
        assertTrue(AnonymousCrashStore.isReportableReason(ApplicationExitInfo.REASON_CRASH))
        assertTrue(AnonymousCrashStore.isReportableReason(ApplicationExitInfo.REASON_CRASH_NATIVE))
        assertTrue(AnonymousCrashStore.isReportableReason(ApplicationExitInfo.REASON_ANR))
        assertFalse(AnonymousCrashStore.isReportableReason(ApplicationExitInfo.REASON_EXIT_SELF))
        assertFalse(AnonymousCrashStore.isReportableReason(ApplicationExitInfo.REASON_USER_REQUESTED))
    }

    @Test
    fun `native descriptions are redacted and bounded`() {
        val output = AnonymousCrashStore.sanitize(
            "failed https://private.example/watch Bearer secret token=private " +
                "magnet:?xt=urn:btih:123 ${"a".repeat(64)}\nnext",
            140,
        )

        assertTrue(output.contains("[URL]"))
        assertTrue(output.contains("Bearer [REDACTED]"))
        assertTrue(output.contains("[MAGNET]"))
        assertFalse(output.contains("private.example"))
        assertFalse(output.contains("token=private"))
        assertFalse(output.contains("secret"))
        assertFalse(output.contains("a".repeat(40)))
        assertTrue(output.length <= 140)
    }

    @Test
    fun `native redactor removes scheme-less and JSON-escaped URLs only`() {
        val output = AnonymousCrashStore.sanitize(
            "fetch cdn.private.example:8443/user/alice/video.m3u8 " +
                "{\"url\":\"https:\\/\\/edge.private.example\\/signed\\/video.m3u8\"} " +
                "keep libmpv.so version 1.2.3 dev.animetv.Player",
            1_000,
        )

        assertEquals(2, Regex("\\[URL\\]").findAll(output).count())
        assertFalse(output.contains("cdn.private.example"))
        assertFalse(output.contains("edge.private.example"))
        assertTrue(output.contains("libmpv.so"))
        assertTrue(output.contains("version 1.2.3"))
        assertTrue(output.contains("dev.animetv.Player"))
    }

    @Test
    fun `native descriptions redact local paths but preserve stack class names`() {
        val output = AnonymousCrashStore.sanitize(
            "content://com.android.providers.media.documents/document/video%3Aprivate-show.mkv\n" +
                "file:///storage/emulated/0/Private%20Episode.mkv\n" +
                "teto+private:document-id-episode-42\n" +
                "/storage/emulated/0/Private Show Episode 7.mkv\n" +
                "C:\\Users\\Viewer\\Videos\\Private Episode 8.mkv\n" +
                "at dev.animetv.anime_tv.MainActivity.onDestroy" +
                "(MainActivity.kt:169)",
            1_000,
        )

        assertTrue(output.contains("[URI]"))
        assertTrue(output.contains("[PATH]"))
        assertFalse(output.contains("private-show"))
        assertFalse(output.contains("document-id-episode-42"))
        assertFalse(output.contains("Private Show Episode 7.mkv"))
        assertFalse(output.contains("Private Episode 8.mkv"))
        assertTrue(
            output.contains(
                "dev.animetv.anime_tv.MainActivity.onDestroy" +
                    "(MainActivity.kt:169)",
            ),
        )
    }

    @Test
    fun `local crash summary ring keeps only 48 hours and is bounded`() {
        val now = 1_800_000_000_000L
        val summaries = buildList {
            add(
                mapOf<String, Any?>(
                    "kind" to "native",
                    "message" to "outside",
                    "occurred_at_ms" to now - (49L * 60L * 60L * 1_000L),
                ),
            )
            repeat(15) { index ->
                add(
                    mapOf<String, Any?>(
                        "kind" to "java",
                        "message" to "crash-$index",
                        "occurred_at_ms" to now - ((15L - index) * 1_000L),
                    ),
                )
            }
        }

        val bounded = AnonymousCrashStore.boundLocalCrashSummaries(summaries, now)
        val history = AnonymousCrashStore.boundLocalCrashSummaryHistory(summaries, now)

        assertEquals(12, bounded.size)
        assertEquals("crash-3", bounded.first()["message"])
        assertEquals("crash-14", bounded.last()["message"])
        assertEquals(1, history.droppedOutsideWindow)
        assertEquals(3, history.droppedForCapacity)
    }

    @Test
    fun `native crash summaries redact watch room source and identity context`() {
        val output = AnonymousCrashStore.sanitize(
            "room_code=23456789 capability=private display_name=Alice " +
                "tracker_id=9988 source_id=raw-source user@example.com 192.168.1.20 " +
                "0123456789abcdef0123456789abcdef",
            1_000,
        )

        assertFalse(output.contains("23456789"))
        assertFalse(output.contains("private"))
        assertFalse(output.contains("Alice"))
        assertFalse(output.contains("9988"))
        assertFalse(output.contains("raw-source"))
        assertFalse(output.contains("user@example.com"))
        assertFalse(output.contains("192.168.1.20"))
        assertFalse(output.contains("0123456789abcdef"))
    }

    @Test
    fun `native redactor covers standalone rooms signed paths auth and networks`() {
        val base32Hash = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        val output = AnonymousCrashStore.sanitize(
            "join 23456789 //cdn.example/video?X-Amz-Signature=private " +
                "edge.example/file?sig=private root.example?signature=root-private " +
                "\"Cookie\":\"session=private-cookie\"\n" +
                "\"display_name\":\"Quoted Viewer\"\n" +
                "Basic private-basic $base32Hash 2001:db8:85a3::8a2e:370:7334 " +
                "::ffff:192.0.2.128 01:23:45:67:89:ab fe80::1%private-zone",
            2_000,
        )

        listOf(
            "23456789",
            "cdn.example",
            "edge.example",
            "root.example",
            "root-private",
            "private-cookie",
            "Quoted Viewer",
            "private-basic",
            base32Hash,
            "2001:db8:85a3::8a2e:370:7334",
            "::ffff:192.0.2.128",
            "01:23:45:67:89:ab",
            "private-zone",
        ).forEach { privateValue -> assertFalse(output.contains(privateValue)) }
        assertTrue(output.contains("[ROOM CODE]"))
        assertTrue(output.contains("[URL]"))
        assertTrue(output.contains("[REDACTED]"))
        assertTrue(output.contains("[NETWORK ADDRESS]"))
    }
}
