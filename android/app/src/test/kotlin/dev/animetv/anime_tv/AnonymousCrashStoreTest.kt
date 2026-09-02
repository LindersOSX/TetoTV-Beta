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

    @Test
    fun `unstructured native tombstone bytes emit a signature only`() {
        val payload = buildList<Byte> {
            addAll(byteArrayOf(0, 1, 2).toList())
            addAll("SIGSEGV".toByteArray().toList())
            add(0)
            addAll("SEGV_MAPERR".toByteArray().toList())
            add(0)
            addAll("null pointer dereference".toByteArray().toList())
            add(0)
            addAll("flutter-worker-3".toByteArray().toList())
            add(0)
            addAll("SurfaceSyncGroup".toByteArray().toList())
            add(0)
            addAll("/data/app/private/lib/arm64/libflutter.so".toByteArray().toList())
            add(0)
            addAll("impeller::RenderPass::GetRenderTargetSize".toByteArray().toList())
            add(0)
            addAll("https://private.example/watch?token=secret".toByteArray().toList())
        }.toByteArray()

        val first = AnonymousCrashStore.summarizeNativeTombstone(payload, 1_800)
        val second = AnonymousCrashStore.summarizeNativeTombstone(payload, 1_800)

        assertEquals(first, second)
        assertTrue(first.contains("native_tombstone_protobuf signature="))
        assertFalse(first.contains("SIGSEGV"))
        assertFalse(first.contains("flutter-worker-3"))
        assertFalse(first.contains("libflutter.so"))
        assertFalse(first.contains("private.example"))
        assertFalse(first.contains("secret"))
        assertFalse(first.contains("/data/app"))
    }

    @Test
    fun `native protobuf tombstone summary is bounded`() {
        val payload = ("SIGSEGV libflutter.so flutter-worker-1 " + "x".repeat(10_000))
            .toByteArray()
        val output = AnonymousCrashStore.summarizeNativeTombstone(payload, 80)

        assertTrue(output.length <= 80)
    }

    @Test
    fun `real tombstone protobuf fields retain only safe frame evidence`() {
        val frame = message(
            varintField(1, 0x1234),
            bytesField(4, "mpv::video::render"),
            bytesField(6, "/data/app/private/files/secret-title/libmpv.so"),
            bytesField(8, "AABBCCDDEEFF0011"),
        )
        val thread = message(
            bytesField(2, "flutter-worker-8"),
            bytesField(4, frame),
        )
        val threadEntry = message(varintField(1, 42), bytesField(2, thread))
        val signal = message(bytesField(2, "SIGSEGV"), bytesField(4, "SEGV_MAPERR"))
        val cause = message(bytesField(1, "null pointer dereference at private episode"))
        val tombstone = message(
            varintField(6, 42),
            bytesField(10, signal),
            bytesField(15, cause),
            bytesField(16, threadEntry),
            bytesField(99, "https://private.example/episode.mkv?token=secret"),
        )

        val output = AnonymousCrashStore.summarizeNativeTombstone(tombstone, 1_800)

        assertTrue(output.contains("signals=SIGSEGV,SEGV_MAPERR"))
        assertTrue(output.contains("reason=null_pointer_dereference"))
        assertTrue(output.contains("threads=flutter-worker"))
        assertTrue(output.contains("rel_pc=0x1234"))
        assertTrue(output.contains("module=libmpv.so"))
        assertTrue(output.contains("function=mpv.video.render"))
        assertTrue(output.contains("build_id=AABBCCDDEEFF0011"))
        assertFalse(output.contains("secret-title"))
        assertFalse(output.contains("private.example"))
        assertFalse(output.contains("episode.mkv"))
    }

    @Test
    fun `breadcrumb context accepts only allowlisted recent bounded events`() {
        val now = 1_800_000_000_000L
        val values = buildList {
            add(AnonymousCrashStore.CrashBreadcrumb("private-title", now - 10))
            add(AnonymousCrashStore.CrashBreadcrumb("activity_created", now - 11 * 60_000L))
            repeat(20) { index ->
                add(
                    AnonymousCrashStore.CrashBreadcrumb(
                        "direct_torrent_service_foreground",
                        now - (20 - index),
                    ),
                )
            }
        }

        val bounded = AnonymousCrashStore.boundBreadcrumbs(values, now)
        val context = AnonymousCrashStore.breadcrumbContext(values, now)

        assertEquals(16, bounded.size)
        assertFalse(context.contains("private-title"))
        assertFalse(context.contains("activity_created"))
        assertTrue(context.contains("direct_torrent_service_foreground"))
    }

    @Test
    fun `malformed tombstone protobuf fails closed and remains bounded`() {
        val malformed = byteArrayOf(0x52, 0xff.toByte(), 0xff.toByte(), 0xff.toByte(), 0x7f)
        val output = AnonymousCrashStore.summarizeNativeTombstone(malformed, 80)

        assertTrue(output.startsWith("native_tombstone_protobuf signature="))
        assertTrue(output.length <= 80)
    }

    @Test
    fun `unrelated protobuf strings never enter native crash summary`() {
        val tombstone = message(
            bytesField(70, "DiscordPrivateViewer"),
            bytesField(71, "/storage/private_episode.so"),
            bytesField(72, "https://private.example/source?token=secret"),
        )

        val output = AnonymousCrashStore.summarizeNativeTombstone(tombstone, 1_800)

        assertTrue(output.startsWith("native_tombstone_protobuf signature="))
        assertFalse(output.contains("DiscordPrivateViewer"))
        assertFalse(output.contains("private_episode"))
        assertFalse(output.contains("private.example"))
        assertFalse(output.contains("secret"))
    }

    @Test
    fun `structured native frames survive final crash detail composition`() {
        val frame = message(
            varintField(1, 0x9876),
            bytesField(4, "mpv::video::render"),
            bytesField(6, "/system/lib64/libmpv.so"),
            bytesField(8, "0011223344556677"),
        )
        val thread = message(bytesField(2, "RenderThread"), bytesField(4, frame))
        val tombstone = message(varintField(6, 9), bytesField(16, message(varintField(1, 9), bytesField(2, thread))))
        val summary = AnonymousCrashStore.summarizeNativeTombstone(tombstone, 1_800)

        val composed = AnonymousCrashStore.composeCrashDetails(
            listOf("exit_context reason=native_crash"),
            summary,
            4_000,
        )

        assertTrue(composed.contains("module=libmpv.so"))
        assertTrue(composed.contains("function=mpv.video.render"))
        assertTrue(composed.contains("rel_pc=0x9876"))
        assertFalse(composed.contains("[URI]"))
    }

    @Test
    fun `foreground service importance is not classified as visible`() {
        assertEquals(
            "foreground_service",
            AnonymousCrashStore.importanceName(125),
        )
        assertEquals("visible", AnonymousCrashStore.importanceName(200))
    }

    private fun message(vararg fields: ByteArray): ByteArray = fields.flatMap { it.toList() }.toByteArray()

    private fun bytesField(number: Int, value: String): ByteArray =
        bytesField(number, value.toByteArray(Charsets.US_ASCII))

    private fun bytesField(number: Int, value: ByteArray): ByteArray = message(
        encodeVarint((number shl 3 or 2).toLong()),
        encodeVarint(value.size.toLong()),
        value,
    )

    private fun varintField(number: Int, value: Long): ByteArray = message(
        encodeVarint((number shl 3).toLong()),
        encodeVarint(value),
    )

    private fun encodeVarint(value: Long): ByteArray {
        var remaining = value
        val output = mutableListOf<Byte>()
        do {
            var byte = (remaining and 0x7f).toInt()
            remaining = remaining ushr 7
            if (remaining != 0L) byte = byte or 0x80
            output.add(byte.toByte())
        } while (remaining != 0L)
        return output.toByteArray()
    }
}
